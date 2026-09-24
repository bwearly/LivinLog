//
//  InboundChangeApplier.swift
//  Livin Log
//
//  Phase 1 (CKSyncEngine migration).
//
//  Applies CKSyncEngine.Event.FetchedRecordZoneChanges to a background NSManagedObjectContext
//  that is deliberately NOT a child of viewContext (per the Phase 1 plan) -- its saves reach
//  viewContext the same sibling-context way NSPersistentCloudKitContainer's own background
//  imports used to: this context's saves post NSManagedObjectContextDidSave, and
//  SyncController's viewContext observer merges them in (see SyncController.swift).
//
//  Records are applied in dependency order -- Household, then HouseholdMember, then Movie, then
//  MovieFeedback, then Viewing -- rather than a single generic "upsert everything, then link
//  everything" pass. This satisfies the same requirement the Phase 1 plan describes ("upsert
//  first, link in a second pass, because arrival order isn't guaranteed"): a fetch against this
//  context sees its own uncommitted pending inserts/edits, so by the time MovieFeedback (which
//  can reference all three of Household/HouseholdMember/Movie) is processed, every type it can
//  link to has already been upserted in this same batch, however CloudKit ordered the raw
//  records within event.modifications.
//
//  Known Phase 1 limitation: a link whose target isn't present anywhere in this fetch batch (or
//  already synced from an earlier one) is left nil rather than retried on a later batch. In
//  practice a household's records are sent together, so this should be rare; worth revisiting
//  if it shows up in the Step 3 device tests.

import CloudKit
import CoreData

final class InboundChangeApplier {
    private let context: NSManagedObjectContext
    private let identityIndex: RecordIdentityIndex

    /// Per-row, per-relationship retry attempt counts for retryUnresolvedLinks(), keyed by
    /// "OwnerEntity.relationshipKey.objectIDURI". In-memory only (resets on relaunch) -- this is
    /// a defense-in-depth safety net, not the primary fix for orphans (see Movie.feedbacks /
    /// Movie.viewing now being Cascade), so it doesn't need to survive a relaunch to be useful.
    private var unresolvedAttemptCounts: [String: Int] = [:]
    private static let maxUnresolvedAttempts = 5

    /// Rows that hit the attempt cap this session -- skipped without re-fetching or re-logging
    /// until the app relaunches (this and unresolvedAttemptCounts both reset then, so the row
    /// gets retried again next launch), or until a new record of the target entity type arrives
    /// in a later batch this same session (see retryUnresolvedLinks' newlyInsertedEntityTypes).
    private var gaveUpThisSession: Set<String> = []

    init(context: NSManagedObjectContext, identityIndex: RecordIdentityIndex) {
        self.context = context
        self.context.transactionAuthor = OutboundChangeTracker.transactionAuthor
        self.context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        self.identityIndex = identityIndex
    }

    func apply(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        context.performAndWait {
            var recordsByType: [String: [CKRecord]] = [:]
            var skippedLegacyModifications = 0

            for modification in event.modifications {
                let record = modification.record
                guard record.recordID.zoneID.zoneName.hasPrefix("Household-") else {
                    // Leftover zone from the old NSPersistentCloudKitContainer mirroring
                    // (com.apple.coredata.cloudkit.zone, com.apple.coredata.cloudkit.share.*).
                    // Never written to, never applied.
                    skippedLegacyModifications += 1
                    continue
                }
                if record is CKShare {
                    SyncLogger.log(SyncLogger.inbound, "skipping CKShare record \(record.recordID) (not expected in Phase 1)")
                    continue
                }
                recordsByType[record.recordType, default: []].append(record)
            }

            let filteredDeletions = event.deletions.filter { $0.recordID.zoneID.zoneName.hasPrefix("Household-") }
            let skippedLegacyDeletions = event.deletions.count - filteredDeletions.count
            let skippedLegacyCount = skippedLegacyModifications + skippedLegacyDeletions

            if skippedLegacyCount > 0 {
                SyncLogger.log(SyncLogger.inbound, "skipped \(skippedLegacyCount) legacy-zone records")
            }

            var newlyInsertedEntityTypes: Set<String> = []

            for record in recordsByType[SyncRecordMapping.RecordType.household] ?? [] {
                let (household, isNew) = fetchOrCreateHousehold(recordName: record.recordID.recordName)
                if isNew { newlyInsertedEntityTypes.insert("Household") }
                SyncRecordMapping.apply(record, to: household)
                indexAfterApply(recordType: SyncRecordMapping.RecordType.household, record: record, object: household)
            }

            for record in recordsByType[SyncRecordMapping.RecordType.member] ?? [] {
                let (member, isNew) = fetchOrCreateMember(recordName: record.recordID.recordName)
                if isNew { newlyInsertedEntityTypes.insert("HouseholdMember") }
                let household = (record["householdRecordName"] as? String).flatMap(fetchHousehold)
                SyncRecordMapping.apply(record, to: member, household: household)
                indexAfterApply(recordType: SyncRecordMapping.RecordType.member, record: record, object: member)
            }

            for record in recordsByType[SyncRecordMapping.RecordType.movie] ?? [] {
                let (movie, isNew) = fetchOrCreateMovie(recordName: record.recordID.recordName)
                if isNew { newlyInsertedEntityTypes.insert("Movie") }
                let household = (record["householdRecordName"] as? String).flatMap(fetchHousehold)
                SyncRecordMapping.apply(record, to: movie, household: household)
                indexAfterApply(recordType: SyncRecordMapping.RecordType.movie, record: record, object: movie)
            }

            for record in recordsByType[SyncRecordMapping.RecordType.feedback] ?? [] {
                let feedback = fetchOrCreateFeedback(recordName: record.recordID.recordName)
                let household = (record["householdRecordName"] as? String).flatMap(fetchHousehold)
                let member = (record["memberRecordName"] as? String).flatMap(fetchMember)
                let movie = (record["movieRecordName"] as? String).flatMap(fetchMovie)
                SyncRecordMapping.apply(record, to: feedback, household: household, member: member, movie: movie)
                indexAfterApply(recordType: SyncRecordMapping.RecordType.feedback, record: record, object: feedback)
            }

            for record in recordsByType[SyncRecordMapping.RecordType.viewing] ?? [] {
                let viewing = fetchOrCreateViewing(recordName: record.recordID.recordName)
                let household = (record["householdRecordName"] as? String).flatMap(fetchHousehold)
                let movie = (record["movieRecordName"] as? String).flatMap(fetchMovie)
                SyncRecordMapping.apply(record, to: viewing, household: household, movie: movie)
                indexAfterApply(recordType: SyncRecordMapping.RecordType.viewing, record: record, object: viewing)
            }

            for deletion in filteredDeletions {
                applyDeletion(recordName: deletion.recordID.recordName)
            }

            // Re-run link resolution for every row in the store whose relationship is still nil
            // but whose target recordName is set -- not just rows touched in this batch, since a
            // target that arrived just now may unblock a link left unresolved by an earlier
            // batch or session.
            retryUnresolvedLinks(newlyInsertedEntityTypes: newlyInsertedEntityTypes)

            identityIndex.flush()

            guard context.hasChanges else { return }
            do {
                try context.save()
                SyncLogger.log(SyncLogger.inbound, "applied \(event.modifications.count - skippedLegacyModifications) modification(s), \(filteredDeletions.count) deletion(s)")
            } catch {
                SyncLogger.error(SyncLogger.inbound, "save failed: \(String(describing: error))")
                context.rollback()
            }
        }
    }

    // MARK: - Link retry

    private func retryUnresolvedLinks(newlyInsertedEntityTypes: Set<String>) {
        var unresolvedCounts: [String: Int] = [:]

        func retry<Owner: NSManagedObject, Target: NSManagedObject>(
            ownerEntityName: String,
            relationshipKey: String,
            recordNameKey: String,
            targetEntityName: String,
            setLink: (Owner, Target) -> Void
        ) {
            // This batch inserted a new row of the type this relationship points at -- a row
            // that gave up earlier this session waiting for exactly that type deserves an
            // immediate retry rather than waiting for relaunch.
            if newlyInsertedEntityTypes.contains(targetEntityName) {
                let prefix = "\(ownerEntityName).\(relationshipKey)."
                gaveUpThisSession = gaveUpThisSession.filter { !$0.hasPrefix(prefix) }
                unresolvedAttemptCounts = unresolvedAttemptCounts.filter { !$0.key.hasPrefix(prefix) }
            }

            let request = NSFetchRequest<Owner>(entityName: ownerEntityName)
            request.predicate = NSPredicate(format: "%K == nil AND %K != nil", relationshipKey, recordNameKey)
            guard let rows = try? context.fetch(request), !rows.isEmpty else { return }

            var stillUnresolved = 0
            for row in rows {
                let attemptKey = "\(ownerEntityName).\(relationshipKey).\(row.objectID.uriRepresentation().absoluteString)"

                guard !gaveUpThisSession.contains(attemptKey) else { continue }

                let targetRecordName = row.value(forKey: recordNameKey) as? String
                let target: Target? = targetRecordName.flatMap {
                    SyncRecordMapping.fetchByRecordName(entityName: targetEntityName, recordName: $0, context: context)
                }

                guard let target else {
                    let attempts = (unresolvedAttemptCounts[attemptKey] ?? 0) + 1
                    if attempts >= Self.maxUnresolvedAttempts {
                        // Give up for this session only -- do NOT clear the scalar. On a fresh
                        // install or a large household, the parent can legitimately arrive several
                        // batches after the child; clearing the pointer would destroy the only
                        // record of that link permanently. A wasted retry is cheap, a lost
                        // relationship isn't -- so just stop retrying until next launch (or until
                        // a new row of the target type arrives this session -- see above).
                        gaveUpThisSession.insert(attemptKey)
                        unresolvedAttemptCounts.removeValue(forKey: attemptKey)
                        SyncLogger.log(SyncLogger.inbound, "giving up on \(ownerEntityName).\(relationshipKey) for this session (target \(targetRecordName ?? "nil"))")
                    } else {
                        unresolvedAttemptCounts[attemptKey] = attempts
                        stillUnresolved += 1
                    }
                    continue
                }
                setLink(row, target)
                unresolvedAttemptCounts.removeValue(forKey: attemptKey)
            }

            if stillUnresolved > 0 {
                unresolvedCounts["\(ownerEntityName).\(relationshipKey)"] = stillUnresolved
            }
        }

        retry(ownerEntityName: "HouseholdMember", relationshipKey: "household", recordNameKey: "householdRecordName", targetEntityName: "Household") { (member: HouseholdMember, household: Household) in
            member.household = household
            member.setValue(household.id, forKey: "householdId")
        }
        retry(ownerEntityName: "Movie", relationshipKey: "household", recordNameKey: "householdRecordName", targetEntityName: "Household") { (movie: Movie, household: Household) in
            movie.household = household
            movie.householdID = household.id
        }
        retry(ownerEntityName: "MovieFeedback", relationshipKey: "household", recordNameKey: "householdRecordName", targetEntityName: "Household") { (feedback: MovieFeedback, household: Household) in
            feedback.household = household
        }
        retry(ownerEntityName: "MovieFeedback", relationshipKey: "member", recordNameKey: "memberRecordName", targetEntityName: "HouseholdMember") { (feedback: MovieFeedback, member: HouseholdMember) in
            feedback.member = member
        }
        retry(ownerEntityName: "MovieFeedback", relationshipKey: "movie", recordNameKey: "movieRecordName", targetEntityName: "Movie") { (feedback: MovieFeedback, movie: Movie) in
            feedback.movie = movie
        }
        retry(ownerEntityName: "Viewing", relationshipKey: "household", recordNameKey: "householdRecordName", targetEntityName: "Household") { (viewing: Viewing, household: Household) in
            viewing.household = household
        }
        retry(ownerEntityName: "Viewing", relationshipKey: "movie", recordNameKey: "movieRecordName", targetEntityName: "Movie") { (viewing: Viewing, movie: Movie) in
            viewing.movie = movie
        }

        if !unresolvedCounts.isEmpty {
            SyncLogger.log(SyncLogger.inbound, "unresolved links after retry: \(unresolvedCounts)")
        }
    }

    // MARK: - Fetch-or-create

    private func fetchOrCreateHousehold(recordName: String) -> (household: Household, isNew: Bool) {
        if let existing: Household = SyncRecordMapping.fetchByRecordName(entityName: "Household", recordName: recordName, context: context) {
            return (existing, false)
        }
        let household = Household(context: context)
        household.recordName = recordName
        return (household, true)
    }

    private func fetchOrCreateMember(recordName: String) -> (member: HouseholdMember, isNew: Bool) {
        if let existing: HouseholdMember = SyncRecordMapping.fetchByRecordName(entityName: "HouseholdMember", recordName: recordName, context: context) {
            return (existing, false)
        }
        let member = HouseholdMember(context: context)
        member.recordName = recordName
        return (member, true)
    }

    private func fetchOrCreateMovie(recordName: String) -> (movie: Movie, isNew: Bool) {
        if let existing: Movie = SyncRecordMapping.fetchByRecordName(entityName: "Movie", recordName: recordName, context: context) {
            return (existing, false)
        }
        let movie = Movie(context: context)
        movie.recordName = recordName
        return (movie, true)
    }

    private func fetchOrCreateFeedback(recordName: String) -> MovieFeedback {
        if let existing: MovieFeedback = SyncRecordMapping.fetchByRecordName(entityName: "MovieFeedback", recordName: recordName, context: context) {
            return existing
        }
        let feedback = MovieFeedback(context: context)
        feedback.recordName = recordName
        return feedback
    }

    private func fetchOrCreateViewing(recordName: String) -> Viewing {
        if let existing: Viewing = SyncRecordMapping.fetchByRecordName(entityName: "Viewing", recordName: recordName, context: context) {
            return existing
        }
        let viewing = Viewing(context: context)
        viewing.recordName = recordName
        return viewing
    }

    // MARK: - Link resolution (falls back to already-synced rows outside this batch)

    private func fetchHousehold(recordName: String) -> Household? {
        SyncRecordMapping.fetchByRecordName(entityName: "Household", recordName: recordName, context: context)
    }

    private func fetchMember(recordName: String) -> HouseholdMember? {
        SyncRecordMapping.fetchByRecordName(entityName: "HouseholdMember", recordName: recordName, context: context)
    }

    private func fetchMovie(recordName: String) -> Movie? {
        SyncRecordMapping.fetchByRecordName(entityName: "Movie", recordName: recordName, context: context)
    }

    // MARK: - Bookkeeping

    /// Keeps RecordIdentityIndex in sync with records we just learned about from the server, so
    /// a later local delete of one of these rows can still be turned into an outbound delete.
    private func indexAfterApply(recordType: String, record: CKRecord, object: NSManagedObject) {
        let objectIDURI = object.objectID.uriRepresentation().absoluteString
        let zoneID = record.recordID.zoneID
        identityIndex.set(
            RecordIdentityIndex.Ref(recordType: recordType, recordName: record.recordID.recordName, zoneName: zoneID.zoneName, zoneOwnerName: zoneID.ownerName),
            for: objectIDURI
        )
    }

    private func applyDeletion(recordName: String) {
        // Registry order (parents first), same order as the hand-written list this replaced.
        for entityName in SyncRecordMapping.entities.map(\.entityName) {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            request.predicate = NSPredicate(format: "recordName == %@", recordName)
            request.fetchLimit = 1
            guard let object = (try? context.fetch(request))?.first else { continue }
            identityIndex.remove(object.objectID.uriRepresentation().absoluteString)
            context.delete(object)
            SyncLogger.log(SyncLogger.inbound, "deleted \(entityName) recordName=\(recordName)")
            return
        }
    }
}
