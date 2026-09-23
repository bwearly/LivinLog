//
//  CloudSharing.swift
//  Livin Log
//

import CoreData
import CloudKit

/// Distinct from `PrepareShareWatchdogTimeoutError` (UICloudSharingControllerRepresentable) so
/// Settings/logs can tell "the export-idle gate itself timed out before share() was even
/// called" apart from "share()'s completion handler never fired." Experimental error for the
/// Task 3 deadlock-hypothesis test, not a permanent user-facing message.
struct ExportIdleWaitTimeoutError: LocalizedError {
    var errorDescription: String? {
        "iCloud sharing could not start because a pending sync operation did not finish in time. Please try again in a moment."
    }
}

/// Phase 1 (CKSyncEngine migration): every function below that used to call an
/// NSPersistentCloudKitContainer-only sharing API (`.share`, `persistUpdatedShare`,
/// `fetchShares`) now throws this instead. Disabled, not deleted, per the migration's hard
/// rule -- the original implementations are preserved in git history / the Phase 1 plan's
/// disable list, and Phase 3 (shared-DB CKSyncEngine) is where real sharing comes back,
/// presumably built on CKShare + UICloudSharingController directly rather than Core Data's
/// mirroring sharing surface.
struct SharingTemporarilyDisabledError: LocalizedError {
    var errorDescription: String? {
        "iCloud sharing is temporarily unavailable while sync is being rebuilt. Please check back soon."
    }
}

enum CloudSharing {
    // Schema safety checklist for TestFlight / Production CloudKit:
    // 1) Any CloudKit-backed Core Data model change must be deployed from Development -> Production schema
    //    in CloudKit Dashboard before shipping TestFlight/App Store builds.
    // 2) Avoid renaming or type-changing existing CloudKit-backed attributes (for example `contextText`),
    //    unless you provide a migration strategy and deploy the updated schema first.
    // 3) TestFlight uses PRODUCTION CloudKit schema; local/simulator success against Development does not
    //    guarantee Production writes will succeed.
    static let lastShareErrorDefaultsKey = "ll_last_cloudkit_share_error"
    static let lastShareStatusDefaultsKey = "ll_last_cloudkit_share_status"

    /// Phase 1: no longer reads `NSPersistentCloudKitContainerOptions` (nothing sets them on a
    /// plain `NSPersistentContainer` store description anymore) -- returns the real container
    /// identifier directly. `persistentContainer` param kept, unused, for call-site compatibility.
    static func containerIdentifier(from persistentContainer: NSPersistentContainer) -> String {
        return PersistenceController.containerId
    }

    static func cloudKitContainer(from persistentContainer: NSPersistentContainer) -> CKContainer {
        let identifier = containerIdentifier(from: persistentContainer)
        return identifier.isEmpty ? CKContainer.default() : CKContainer(identifier: identifier)
    }

    static func accountStatus(using persistentContainer: NSPersistentContainer) async -> CKAccountStatus {
        let container = cloudKitContainer(from: persistentContainer)

        do {
            return try await container.accountStatus()
        } catch {
            return .couldNotDetermine
        }
    }

    static func isShareActionAvailable(for status: CKAccountStatus) -> Bool {
        status == .available
    }

    static func fetchShare(
        for objectID: NSManagedObjectID,
        persistentContainer: NSPersistentContainer
    ) throws -> CKShare? {
        throw SharingTemporarilyDisabledError()
    }

    static func fetchOrCreateShare(
        for household: Household,
        in context: NSManagedObjectContext,
        persistentContainer: NSPersistentContainer
    ) async throws -> CKShare {
        throw SharingTemporarilyDisabledError()
    }

    static func saveLastShareStatus(_ text: String) {
        UserDefaults.standard.set(text, forKey: lastShareStatusDefaultsKey)
    }

    static func saveLastShareError(_ text: String?) {
        UserDefaults.standard.set(text, forKey: lastShareErrorDefaultsKey)
    }

    static func technicalDetails(for error: Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)"
    }

    static func friendlySharingErrorMessage(forTechnicalDetails technicalDetails: String) -> String {
        if technicalDetails.localizedCaseInsensitiveContains("CD_moveReceipt")
            || technicalDetails.localizedCaseInsensitiveContains("Cannot create or modify field")
            || technicalDetails.localizedCaseInsensitiveContains("production schema") {
            return "iCloud sharing could not finish because the app data schema is out of sync."
        }

        return "iCloud sharing could not finish. Show technical details for debugging information."
    }

    static func stopSharing(
        share: CKShare,
        persistentContainer: NSPersistentContainer
    ) async throws {
        throw SharingTemporarilyDisabledError()
    }

    /// Called by a participant (never the owner) to leave a shared household on their own.
    ///
    /// Phase 1 (CKSyncEngine migration): deliberately a no-op, NOT a throw -- this differs from
    /// the other disabled functions above. The pre-migration contract here was already "if no
    /// CKShare is resolvable, log and return so the caller's local depart step still proceeds
    /// (a member isn't blocked from leaving locally by a CloudKit-side lookup gap)." With
    /// sharing disabled there is never a resolvable CKShare, so that same no-op path is now
    /// always taken -- `HouseholdProfileManagementView.swift`'s leave-household flow keeps
    /// working exactly as it did before for the local-depart half.
    static func leaveShare(
        for household: Household,
        persistentContainer: NSPersistentContainer
    ) async throws {
        print("⚠️ [CloudSharing] leaveShare: sharing disabled in Phase 1; skipping CloudKit-side leave for household=\(household.name ?? "Household")")
    }
}
