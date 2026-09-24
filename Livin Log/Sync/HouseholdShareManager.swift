//
//  HouseholdShareManager.swift
//  Livin Log
//
//  Phase 3b (sharing). Modeled on SyncSpike/HouseholdShareManager.swift's proven pattern: the
//  household's zone-wide CKShare is created and saved directly via `CKDatabase.save(_:)`, never
//  through CKSyncEngine's pendingRecordZoneChanges/nextRecordZoneChangeBatch pipeline -- that's
//  the only documented pattern; CKSyncEngine has no API that takes a CKShare as a pending change.
//
//  One correction from the spike and from the Phase 3b plan's original description: the share's
//  `publicPermission` is `.none`, not `.readWrite`. Confirmed against CKShare.h:
//  `addParticipant`/`removeParticipant` both require `publicPermission == .none` ("You can't mix
//  and match public and private users in the same share"), and switching an existing share's
//  `publicPermission` to `.none` removes ALL participants, not just one -- so a `.readWrite`
//  link-based share can never have a single participant selectively removed, which the Phase 3b
//  "Remove access" requirement needs. Instead, each invited member gets their own
//  `CKShare.Participant.oneTimeURLParticipant()` (confirmed in CKShareParticipant.h, iOS 18+,
//  this app's deployment target is iOS 26) -- built for exactly this "don't know their identity
//  up front, but need to address/remove them individually later" scenario.

import CloudKit
import CoreData

enum HouseholdShareManager {

    struct InviteResult {
        let url: URL
        let participantID: CKShare.Participant.ID
    }

    /// Fetches the household's zone-wide CKShare if one already exists, without creating one.
    /// `CKRecordNameZoneWideShare` is the well-known record name CloudKit assigns to a share
    /// created via `CKShare(recordZoneID:)` (confirmed in CKShare.h).
    static func fetchExistingShare(for household: Household, container: CKContainer) async throws -> CKShare? {
        guard let zoneID = SyncRecordMapping.zoneID(for: household) else { return nil }
        let shareRecordID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        do {
            let record = try await container.privateCloudDatabase.record(for: shareRecordID)
            return record as? CKShare
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    /// Creates the household's zone-wide CKShare the first time it's needed (lazily, on the
    /// first Invite tap) and returns it thereafter without re-creating it.
    static func fetchOrCreateShare(for household: Household, container: CKContainer) async throws -> CKShare {
        if let existing = try await fetchExistingShare(for: household, container: container) {
            return existing
        }
        guard let zoneID = SyncRecordMapping.zoneID(for: household) else {
            throw NSError(
                domain: "HouseholdShareManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "This household hasn't finished syncing yet. Try again in a moment."]
            )
        }
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = (household.name ?? "Household") as CKRecordValue
        share.publicPermission = .none
        let saved = try await container.privateCloudDatabase.save(share)
        guard let savedShare = saved as? CKShare else {
            throw NSError(domain: "HouseholdShareManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Saved record was not a CKShare."])
        }
        return savedShare
    }

    /// Invites `member`: creates the share if needed, adds a one-time-URL participant for them
    /// (or reuses their existing one -- see "Resend"), and returns its shareable URL. The caller
    /// is responsible for stamping the returned `participantID` onto
    /// `member.inviteParticipantID` and `invitedAt` on success.
    static func invite(member: HouseholdMember, household: Household, container: CKContainer) async throws -> InviteResult {
        let share = try await fetchOrCreateShare(for: household, container: container)

        // Resend: this member already has a participant on the share -- one-time URLs are
        // stable and tied to their participantID for as long as they're part of the share
        // (confirmed in CKShareParticipant.h), so no new participant is needed.
        if let existingID = member.value(forKey: "inviteParticipantID") as? String,
           let url = share.oneTimeURL(for: existingID) {
            return InviteResult(url: url, participantID: existingID)
        }

        let participant = CKShare.Participant.oneTimeURLParticipant()
        participant.permission = .readWrite
        share.addParticipant(participant)

        let saved = try await container.privateCloudDatabase.save(share)
        guard let savedShare = saved as? CKShare else {
            throw NSError(domain: "HouseholdShareManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Saved record was not a CKShare."])
        }
        guard let url = savedShare.oneTimeURL(for: participant.participantID) else {
            throw NSError(domain: "HouseholdShareManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not generate an invite link for this member."])
        }
        return InviteResult(url: url, participantID: participant.participantID)
    }

    /// Revokes `member`'s CloudKit access to the household's zone. Resolves the participant by
    /// `inviteParticipantID` first (works even for a pending, not-yet-accepted invite, since the
    /// participant already exists on the share before acceptance), falling back to matching
    /// `userIdentity.userRecordID.recordName` against `linkedUserRecordName` per the Phase 3b
    /// plan. A no-op (not an error) if no matching participant is found on the share -- the
    /// caller still clears the member's local link fields regardless.
    static func removeAccess(for member: HouseholdMember, household: Household, container: CKContainer) async throws {
        guard let share = try await fetchExistingShare(for: household, container: container) else { return }

        let participantID = member.value(forKey: "inviteParticipantID") as? String
        let linkedUserRecordName = member.value(forKey: "linkedUserRecordName") as? String

        let participant = share.participants.first { candidate in
            if let participantID, candidate.participantID == participantID { return true }
            if let linkedUserRecordName, !linkedUserRecordName.isEmpty,
               candidate.userIdentity.userRecordID?.recordName == linkedUserRecordName { return true }
            return false
        }

        guard let participant else { return }

        share.removeParticipant(participant)
        _ = try await container.privateCloudDatabase.save(share)
    }

    /// Keeps the share's title (shown in the system's invite/accept UI) in step with a renamed
    /// household. A no-op if the household has never been shared or the title already matches.
    static func updateTitle(to title: String, for household: Household, container: CKContainer) async throws {
        guard let share = try await fetchExistingShare(for: household, container: container) else { return }
        guard (share[CKShare.SystemFieldKey.title] as? String) != title else { return }
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        _ = try await container.privateCloudDatabase.save(share)
    }

    /// Participant's "Leave Household": deletes the zone-wide share record from this device's
    /// *shared* database. Confirmed in CKShare.h: "If a participant attempts to delete the share,
    /// CloudKit removes the participant. The share remains active for all other participants."
    /// (Deleting the zone from the shared database instead is undocumented, so not used.) An
    /// already-missing share or zone counts as success -- there's nothing left to leave.
    static func leave(household: Household, container: CKContainer) async throws {
        guard let zoneID = SyncRecordMapping.zoneID(for: household) else {
            throw NSError(domain: "HouseholdShareManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "This household hasn't finished syncing yet. Try again in a moment."])
        }
        let shareRecordID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        do {
            _ = try await container.sharedCloudDatabase.deleteRecord(withID: shareRecordID)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return
        }
    }
}
