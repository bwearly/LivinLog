//
//  OutboundChangeTracker.swift
//  Livin Log
//
//  Phase 1 (CKSyncEngine migration).
//
//  Detects local writes via NSPersistentHistoryChangeRequest -- Core Data's own mechanism for
//  "what changed since I last looked," independent of which of the many existing Movie/
//  MovieFeedback/Viewing/Household/HouseholdMember view call sites made the change. This is
//  why none of those call sites needed to change for outbound sync to work: every save that
//  touches the store posts NSPersistentStoreRemoteChangeNotification (already enabled --
//  PersistenceController kept NSPersistentHistoryTrackingKey and
//  NSPersistentStoreRemoteChangeNotificationPostOptionKey on), which is what triggers
//  processNewChanges below.
//
//  Skips history authored "sync" (see transactionAuthor) so InboundChangeApplier's own writes
//  don't get re-detected and queued right back out.

import CloudKit
import CoreData

final class OutboundChangeTracker {
    static let transactionAuthor = "sync"

    private let context: NSManagedObjectContext
    private let tokenFileURL: URL
    private let identityIndex: RecordIdentityIndex

    // Tracked entities and their synced properties come from SyncRecordMapping.entities (the
    // single source of truth). Properties exclude every to-many *inverse* relationship (e.g.
    // Household.movies) -- setting `movie.household = household` produces a spurious `.update`
    // history change on the Household side too (its inverse relationship changed), even though
    // nothing in Household's own CKRecord did. processNewChanges uses them to skip those
    // relationship-only updates rather than queuing a pointless resend.

    init(context: NSManagedObjectContext, tokenFileURL: URL, identityIndex: RecordIdentityIndex) {
        self.context = context
        self.tokenFileURL = tokenFileURL
        self.identityIndex = identityIndex
    }

    private func loadToken() -> NSPersistentHistoryToken? {
        guard let data = try? Data(contentsOf: tokenFileURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
    }

    private func save(token: NSPersistentHistoryToken) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        try? data.write(to: tokenFileURL, options: .atomic)
    }

    /// Scans persistent history since the last processed token and enqueues pending changes on
    /// whichever engine owns each change's zone -- a record whose zone's owner is this device
    /// (`CKCurrentUserDefaultName`, for a not-yet-synced local zone, or a matching
    /// `currentUserRecordName` once it has synced) goes to `privateEngine`; everything else (a
    /// household this device only participates in) goes to `sharedEngine`. Safe to call
    /// repeatedly (every remote-change notification, plus once at launch); a no-op when there's
    /// nothing new.
    func processNewChanges(privateEngine: CKSyncEngine, sharedEngine: CKSyncEngine, currentUserRecordName: String?) {
        context.performAndWait {
            let sinceToken = loadToken()
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: sinceToken)
            guard let result = try? context.execute(request) as? NSPersistentHistoryResult,
                  let transactions = result.result as? [NSPersistentHistoryTransaction],
                  !transactions.isEmpty else {
                return
            }

            var privateChanges: [CKSyncEngine.PendingRecordZoneChange] = []
            var sharedChanges: [CKSyncEngine.PendingRecordZoneChange] = []

            func enqueue(_ change: CKSyncEngine.PendingRecordZoneChange, zoneOwnerName: String) {
                let isOwnedByMe = zoneOwnerName == CKCurrentUserDefaultName || zoneOwnerName == currentUserRecordName
                if isOwnedByMe {
                    privateChanges.append(change)
                } else {
                    sharedChanges.append(change)
                }
            }

            for transaction in transactions {
                guard transaction.author != Self.transactionAuthor else { continue }
                for change in transaction.changes ?? [] {
                    guard let entityName = change.changedObjectID.entity.name,
                          SyncRecordMapping.syncedEntityNames.contains(entityName) else { continue }

                    let objectIDURI = change.changedObjectID.uriRepresentation().absoluteString

                    switch change.changeType {
                    case .insert:
                        guard let object = try? context.existingObject(with: change.changedObjectID),
                              let ref = Self.recordRef(for: object) else { continue }
                        identityIndex.set(ref, for: objectIDURI)
                        enqueue(.saveRecord(ref.recordID), zoneOwnerName: ref.zoneOwnerName)

                    case .update:
                        if let updated = change.updatedProperties, !updated.isEmpty {
                            let updatedNames = Set(updated.map(\.name))
                            let mapped = SyncRecordMapping.spec(forEntityName: entityName)?.syncedProperties ?? []
                            if updatedNames.isDisjoint(with: mapped) {
                                // Relationship-inverse-only (or otherwise unmapped) change --
                                // nothing SyncRecordMapping would write differs, so skip the resend.
                                continue
                            }
                        }
                        guard let object = try? context.existingObject(with: change.changedObjectID),
                              let ref = Self.recordRef(for: object) else { continue }
                        identityIndex.set(ref, for: objectIDURI)
                        enqueue(.saveRecord(ref.recordID), zoneOwnerName: ref.zoneOwnerName)

                    case .delete:
                        if let ref = identityIndex.ref(for: objectIDURI) {
                            enqueue(.deleteRecord(ref.recordID), zoneOwnerName: ref.zoneOwnerName)
                        }
                        identityIndex.remove(objectIDURI)

                    @unknown default:
                        break
                    }
                }
            }

            identityIndex.flush()

            if !privateChanges.isEmpty {
                SyncLogger.log(SyncLogger.outbound, "queuing \(privateChanges.count) pending change(s) on privateEngine")
                privateEngine.state.add(pendingRecordZoneChanges: privateChanges)
            }
            if !sharedChanges.isEmpty {
                SyncLogger.log(SyncLogger.outbound, "queuing \(sharedChanges.count) pending change(s) on sharedEngine")
                sharedEngine.state.add(pendingRecordZoneChanges: sharedChanges)
            }

            if let newToken = transactions.last?.token {
                save(token: newToken)
                // Phase 1's only history consumer is this tracker (NSPersistentCloudKitContainer
                // used to prune history itself as part of its own export; now nothing does, so
                // this tracker prunes what it has already processed to bound store growth).
                let pruneRequest = NSPersistentHistoryChangeRequest.deleteHistory(before: newToken)
                _ = try? context.execute(pruneRequest)
            }
        }
    }

    private static func recordRef(for object: NSManagedObject) -> RecordIdentityIndex.Ref? {
        // Uses SyncRecordMapping.zoneID(for:) (ckSystemFields-first) rather than deriving from
        // household.id directly, for the same reason makeRecord(for:) does: household.id can be
        // wrong locally (e.g. regenerated by awakeFromInsert on an inbound-created row before an
        // "id" field existed on the server record), and the two must never diverge.
        func ref(recordType: String, recordName: String?, household: Household?) -> RecordIdentityIndex.Ref? {
            guard let recordName, let household, let zoneID = SyncRecordMapping.zoneID(for: household) else { return nil }
            return RecordIdentityIndex.Ref(recordType: recordType, recordName: recordName, zoneName: zoneID.zoneName, zoneOwnerName: zoneID.ownerName)
        }

        switch object {
        case let household as Household:
            return ref(recordType: SyncRecordMapping.RecordType.household, recordName: household.recordName, household: household)
        case let member as HouseholdMember:
            return ref(recordType: SyncRecordMapping.RecordType.member, recordName: member.recordName, household: member.household)
        case let movie as Movie:
            return ref(recordType: SyncRecordMapping.RecordType.movie, recordName: movie.recordName, household: movie.household)
        case let feedback as MovieFeedback:
            return ref(recordType: SyncRecordMapping.RecordType.feedback, recordName: feedback.recordName, household: feedback.household)
        case let viewing as Viewing:
            return ref(recordType: SyncRecordMapping.RecordType.viewing, recordName: viewing.recordName, household: viewing.household)
        default:
            return nil
        }
    }
}
