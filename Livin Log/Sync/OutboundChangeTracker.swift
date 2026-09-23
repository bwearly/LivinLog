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

    private static let trackedEntityNames: Set<String> = [
        "Household", "HouseholdMember", "Movie", "MovieFeedback", "Viewing"
    ]

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
    /// `engine`. Safe to call repeatedly (every remote-change notification, plus once at
    /// launch); a no-op when there's nothing new.
    func processNewChanges(engine: CKSyncEngine) {
        context.performAndWait {
            let sinceToken = loadToken()
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: sinceToken)
            guard let result = try? context.execute(request) as? NSPersistentHistoryResult,
                  let transactions = result.result as? [NSPersistentHistoryTransaction],
                  !transactions.isEmpty else {
                return
            }

            var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []

            for transaction in transactions {
                guard transaction.author != Self.transactionAuthor else { continue }
                for change in transaction.changes ?? [] {
                    guard let entityName = change.changedObjectID.entity.name,
                          Self.trackedEntityNames.contains(entityName) else { continue }

                    let objectIDURI = change.changedObjectID.uriRepresentation().absoluteString

                    switch change.changeType {
                    case .insert, .update:
                        guard let object = try? context.existingObject(with: change.changedObjectID),
                              let ref = Self.recordRef(for: object) else { continue }
                        identityIndex.set(ref, for: objectIDURI)
                        pendingChanges.append(.saveRecord(ref.recordID))

                    case .delete:
                        if let ref = identityIndex.ref(for: objectIDURI) {
                            pendingChanges.append(.deleteRecord(ref.recordID))
                        }
                        identityIndex.remove(objectIDURI)

                    @unknown default:
                        break
                    }
                }
            }

            identityIndex.flush()

            if !pendingChanges.isEmpty {
                SyncLogger.log(SyncLogger.outbound, "queuing \(pendingChanges.count) pending change(s)")
                engine.state.add(pendingRecordZoneChanges: pendingChanges)
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
        func ref(recordType: String, recordName: String?, householdID: UUID?) -> RecordIdentityIndex.Ref? {
            guard let recordName, let householdID else { return nil }
            let zoneID = SyncRecordMapping.zoneID(householdID: householdID)
            return RecordIdentityIndex.Ref(recordType: recordType, recordName: recordName, zoneName: zoneID.zoneName, zoneOwnerName: zoneID.ownerName)
        }

        switch object {
        case let household as Household:
            return ref(recordType: SyncRecordMapping.RecordType.household, recordName: household.recordName, householdID: household.id)
        case let member as HouseholdMember:
            return ref(recordType: SyncRecordMapping.RecordType.member, recordName: member.recordName, householdID: member.household?.id)
        case let movie as Movie:
            return ref(recordType: SyncRecordMapping.RecordType.movie, recordName: movie.recordName, householdID: movie.household?.id)
        case let feedback as MovieFeedback:
            return ref(recordType: SyncRecordMapping.RecordType.feedback, recordName: feedback.recordName, householdID: feedback.household?.id)
        case let viewing as Viewing:
            return ref(recordType: SyncRecordMapping.RecordType.viewing, recordName: viewing.recordName, householdID: viewing.household?.id)
        default:
            return nil
        }
    }
}
