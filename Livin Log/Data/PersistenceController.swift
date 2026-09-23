//
//  Persistence.swift
//  Livin Log
//

import CoreData
import CloudKit
import Foundation

struct PersistenceLoadError: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let storeURL: URL?
    let configuration: String
    let underlyingDomain: String
    let underlyingCode: Int
    let underlyingUserInfo: [String: String]

    init(error: NSError, description: NSPersistentStoreDescription) {
        self.message = error.localizedDescription
        self.storeURL = description.url
        self.configuration = description.configuration ?? "default"
        self.underlyingDomain = error.domain
        self.underlyingCode = error.code
        self.underlyingUserInfo = error.userInfo.reduce(into: [:]) { partialResult, pair in
            partialResult[String(describing: pair.key)] = String(describing: pair.value)
        }
    }
}

/// Tracks per-store in-flight CloudKit export state from the (now-disabled, Phase 1)
/// `NSPersistentCloudKitContainer.eventChangedNotification` observer, so `CloudSharing`
/// could check/wait for export-idle before calling `persistentContainer.share(...)`.
///
/// Phase 1 (CKSyncEngine migration): nothing produces `.eventChangedNotification` anymore
/// (see `PersistenceController.init()` below), so nothing calls `markExportStarted`/
/// `markExportEnded` and this tracker is permanently idle. Left in place, unmodified, per the
/// "disable, don't delete" rule -- it's sharing-support infrastructure, not mirroring-specific,
/// and Phase 3 may still want it once the shared-DB engine exists.
final class CloudKitExportTracker {
    static let shared = CloudKitExportTracker()
    private init() {}

    /// "A few seconds" per the experiment spec, and short enough to leave room inside the
    /// existing 9s prepareShare watchdog (UICloudSharingControllerRepresentable) so a caller
    /// waiting here still has time left for the actual share() call before that outer watchdog
    /// fires. If this value and the outer watchdog need independent tuning later, that's a sign
    /// this gate belongs in the caller's timeout budget explicitly rather than being implicit.
    static let exportIdleWaitTimeout: TimeInterval = 5.0

    private let queue = DispatchQueue(label: "CloudKitExportTracker")
    private var inFlightStoreIdentifiers: Set<String> = []
    private var waiters: [String: [(Bool) -> Void]] = [:]

    func markExportStarted(storeIdentifier: String) {
        queue.async {
            self.inFlightStoreIdentifiers.insert(storeIdentifier)
        }
    }

    func markExportEnded(storeIdentifier: String) {
        queue.async {
            self.inFlightStoreIdentifiers.remove(storeIdentifier)
            let pending = self.waiters.removeValue(forKey: storeIdentifier) ?? []
            pending.forEach { $0(true) }
        }
    }

    func isExportInFlight(storeIdentifier: String) -> Bool {
        queue.sync {
            inFlightStoreIdentifiers.contains(storeIdentifier)
        }
    }

    /// Resolves `true` if idle now or once the in-flight export clears; `false` if `timeout`
    /// elapses first. Never throws — the caller decides what a timed-out wait means.
    func waitForExportIdle(storeIdentifier: String, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async {
                guard self.inFlightStoreIdentifiers.contains(storeIdentifier) else {
                    continuation.resume(returning: true)
                    return
                }

                var resumed = false
                let resumeOnce: (Bool) -> Void = { result in
                    self.queue.async {
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(returning: result)
                    }
                }

                self.waiters[storeIdentifier, default: []].append(resumeOnce)

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    resumeOnce(false)
                }
            }
        }
    }
}

struct PersistenceController {
    static let shared = PersistenceController()

    // Phase 1 (CKSyncEngine migration): plain NSPersistentContainer, single store. No
    // NSPersistentCloudKitContainerOptions, no CloudKit mirroring for any entity. Movies sync
    // via `Sync/SyncController.swift` instead; see the Phase 1 plan for why every other entity
    // goes device-local for now.
    let container: NSPersistentContainer

    /// The single on-disk store. Named `privateStore` (not just `store`) to match the many
    /// existing `== PersistenceController.shared.privateStore` call sites across the app —
    /// renaming would touch files outside this phase's scope for no behavioral benefit.
    let privateStore: NSPersistentStore!

    /// Always `nil` now that there is only one store. Kept (not removed) because a dozen call
    /// sites across HouseholdProfileManagementView/AppState/SettingsView compare
    /// `== PersistenceController.shared.sharedStore` to detect "is this a shared household" —
    /// with this always nil, those comparisons are simply always false, which is exactly the
    /// correct Phase 1 behavior (no household is ever shared) without touching those files.
    let sharedStore: NSPersistentStore!

    /// Non-nil when Core Data/CloudKit stores could not be opened. The app should
    /// render recovery UI instead of touching the managed object context.
    let loadError: PersistenceLoadError?

    var isLoaded: Bool { loadError == nil }

    /// Still the real CloudKit container identifier -- `Sync/SyncController.swift` reuses this
    /// (via the now-internal, not private, access level below) rather than duplicating the string.
    static let containerId = "iCloud.com.blakeearly.livinlog"

    private static func storeURLs() -> (privateURL: URL, sharedURL: URL) {
        let storeDirectory = NSPersistentContainer.defaultDirectoryURL()
        return (
            storeDirectory.appendingPathComponent("LivinLog.sqlite"),
            storeDirectory.appendingPathComponent("LivinLog-shared.sqlite")
        )
    }

    init(inMemory: Bool = false) {
        let container = NSPersistentContainer(name: "LivinLog")
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "<unknown>"
        print("ℹ️ PersistenceController init bundleIdentifier=\(bundleIdentifier) persistentContainerName=\(container.name)")

        let apsEnvironment = Self.detectAPSEnvironment()
        print("🌐 [CloudKitEnvironment] embedded.mobileprovision aps-environment=\(apsEnvironment)")
        switch apsEnvironment {
        case "development":
            print("🌐 [CloudKitEnvironment] ⚠️ This build is running against the CloudKit DEVELOPMENT/Sandbox environment, NOT Production. Any household/share repro captured on this build does NOT validate anything against the real Production household — treat those captures as sandbox-only evidence.")
        case "production":
            print("🌐 [CloudKitEnvironment] This build is running against the CloudKit PRODUCTION environment.")
        default:
            print("🌐 [CloudKitEnvironment] ⚠️ Could not determine aps-environment (\(apsEnvironment)). No embedded.mobileprovision usually means an App Store/TestFlight-processed build (Production) or a Simulator run (no CloudKit provisioning at all) — do not assume which one without corroborating evidence.")
        }

        // Phase 1 (CKSyncEngine migration): single store. The `LivinLog-shared.sqlite` store
        // (recipient shared-database mirror) is retired along with NSPersistentCloudKitContainer
        // mirroring; `storeURLs()` still returns both URLs unchanged (harmless) but only the
        // private URL is used below.
        let urls = Self.storeURLs()
        let privateURL = urls.privateURL

        let privateDesc = NSPersistentStoreDescription(url: privateURL)

        // Keep the store on the model's default configuration. A previous build or a future
        // refactor that writes with a named configuration and then opens it with another is
        // what produces Core Data's "model configuration ... incompatible" launch failure.
        // This app does not define named model configurations, so be explicit and log it.
        privateDesc.configuration = nil

        if inMemory {
            privateDesc.url = URL(fileURLWithPath: "/dev/null")
        }

        print("ℹ️ PersistenceController CloudKit containerIdentifier=\(Self.containerId) (unused for store mirroring in Phase 1 — kept for Sync/SyncController.swift's CKContainer)")

        // Common store options. Persistent history tracking + remote-change notifications stay
        // ON: Sync/InboundChangeApplier.swift's background context saves rely on the same
        // mechanism to propagate into viewContext that NSPersistentCloudKitContainer's
        // background imports used to.
        privateDesc.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        privateDesc.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        privateDesc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        privateDesc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        privateDesc.shouldMigrateStoreAutomatically = true
        privateDesc.shouldInferMappingModelAutomatically = true

        container.persistentStoreDescriptions = [privateDesc]

        Self.logLoadedModelDiagnostics(container: container, reason: "before loadPersistentStores")

        var capturedLoadError: PersistenceLoadError?
        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                Self.logPersistentStoreFailure(error, description: description)
                capturedLoadError = PersistenceLoadError(error: error, description: description)
                return
            }

            print("ℹ️ Loaded persistent store url=\(description.url?.absoluteString ?? "<nil>") configuration=\(description.configuration ?? "default") migrate=\(description.shouldMigrateStoreAutomatically) infer=\(description.shouldInferMappingModelAutomatically)")
            Self.logStoreMetadata(at: description.url)
        }

        self.container = container

        guard capturedLoadError == nil else {
            self.privateStore = nil
            self.sharedStore = nil
            self.loadError = capturedLoadError
            container.viewContext.automaticallyMergesChangesFromParent = false
            print("⚠️ [Persistence] Store load failed; app will show StoreRecoveryView instead of using Core Data.")
            return
        }

        // Resolve the store by URL from the coordinator after load.
        func store(matching url: URL) -> NSPersistentStore? {
            container.persistentStoreCoordinator.persistentStores.first { $0.url == url }
        }

        guard let p = store(matching: privateURL) else {
            let error = NSError(
                domain: "PersistenceController",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to resolve the private store after loading."]
            )
            let description = NSPersistentStoreDescription(url: privateURL)
            Self.logPersistentStoreFailure(error, description: description)
            self.privateStore = nil
            self.sharedStore = nil
            self.loadError = PersistenceLoadError(error: error, description: description)
            return
        }

        self.privateStore = p
        self.sharedStore = nil
        self.loadError = nil

        Self.logLoadedModelDiagnostics(container: container, reason: "after loadPersistentStores")

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        // Phase 1 (CKSyncEngine migration): disabled, not deleted. Nothing posts
        // NSPersistentCloudKitContainer.eventChangedNotification anymore since `container` is a
        // plain NSPersistentContainer — this whole block is dead. Sync/SyncController.swift's
        // own [SYNC]-prefixed CKSyncEngine event logging is the new visibility layer that
        // replaces it. Left commented out (rather than removed) for reference.
        //
        // NotificationCenter.default.addObserver(
        //     forName: NSPersistentCloudKitContainer.eventChangedNotification,
        //     object: container,
        //     queue: .main
        // ) { notification in
        //     guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
        //         as? NSPersistentCloudKitContainer.Event else { return }
        //
        //     let typeText: String
        //     switch event.type {
        //     case .setup: typeText = "setup"
        //     case .import: typeText = "import"
        //     case .export: typeText = "export"
        //     @unknown default: typeText = "unknown"
        //     }
        //
        //     print("☁️ [CKEvent] type=\(typeText) succeeded=\(event.succeeded) storeURL=\(event.storeIdentifier) start=\(event.startDate.description ?? "nil") end=\(event.endDate?.description ?? "nil")")
        //
        //     if let error = event.error {
        //         let nsError = error as NSError
        //         print("☁️ [CKEvent] ❌ domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
        //     }
        //
        //     if event.type == .export {
        //         if event.endDate == nil {
        //             CloudKitExportTracker.shared.markExportStarted(storeIdentifier: event.storeIdentifier)
        //         } else {
        //             CloudKitExportTracker.shared.markExportEnded(storeIdentifier: event.storeIdentifier)
        //         }
        //     }
        // }
    }

    private static func logLoadedModelDiagnostics(container: NSPersistentContainer, reason: String) {
        let model = container.managedObjectModel
        let entityNames = model.entities.compactMap(\.name).sorted()
        let versionIdentifiers = model.versionIdentifiers.map { String(describing: $0) }.sorted()
        let modelConfigurationNames = Array(model.configurations).sorted()
        let storeURLs = container.persistentStoreCoordinator.persistentStores
            .compactMap { store -> String? in
                guard let url = store.url else { return nil }
                return "\(store.type):\(url.absoluteString)"
            }
            .sorted()

        let bookEntryAttributes = model.entitiesByName["BookEntry"]?
            .attributesByName
            .keys
            .sorted() ?? []
        let hasMoveReceipt = bookEntryAttributes.contains("moveReceipt")

        print("ℹ️ [CoreDataModelDiagnostics] reason=\(reason)")
        print("ℹ️ [CoreDataModelDiagnostics] modelVersionIdentifiers=\(versionIdentifiers.isEmpty ? ["<none>"] : versionIdentifiers)")
        print("ℹ️ [CoreDataModelDiagnostics] modelConfigurations=\(modelConfigurationNames.isEmpty ? ["<default>"] : modelConfigurationNames)")
        print("ℹ️ [CoreDataModelDiagnostics] loadedPersistentStoreURLs=\(storeURLs.isEmpty ? ["<none loaded>"] : storeURLs)")
        print("ℹ️ [CoreDataModelDiagnostics] entities=\(entityNames)")
        print("ℹ️ [CoreDataModelDiagnostics] BookEntry.attributes=\(bookEntryAttributes)")
        print("ℹ️ [CoreDataModelDiagnostics] BookEntry.hasMoveReceipt=\(hasMoveReceipt)")

        if hasMoveReceipt {
            print("⚠️ [CoreDataModelDiagnostics] Loaded BookEntry still contains moveReceipt; this build can try to export CD_moveReceipt to CloudKit.")
        }
    }

    /// Reads the `aps-environment` entitlement out of the app's embedded provisioning
    /// profile, at runtime, without guessing. `embedded.mobileprovision` is a CMS/PKCS#7-signed
    /// blob, not a plain plist, but it contains one verbatim `<plist>...</plist>` XML document
    /// as its payload; the standard technique (used by fastlane, Xcode-adjacent tooling, etc.)
    /// is to scan the raw bytes for that substring rather than parse the CMS envelope.
    ///
    /// Returns "development", "production", or a bracketed diagnostic string explaining why
    /// neither could be determined (e.g. no embedded profile at all, which is normal for both
    /// Simulator builds and App Store/TestFlight-processed builds — Apple strips the profile
    /// during App Store processing, so its absence alone does not tell you which environment
    /// you're in).
    private static func detectAPSEnvironment() -> String {
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profileData = try? Data(contentsOf: profileURL) else {
            return "<no embedded.mobileprovision found (Simulator or App Store/TestFlight build)>"
        }

        guard let profileText = String(data: profileData, encoding: .isoLatin1) else {
            return "<embedded.mobileprovision could not be decoded>"
        }

        guard let plistStart = profileText.range(of: "<?xml"),
              let plistEnd = profileText.range(of: "</plist>") else {
            return "<could not locate embedded plist inside embedded.mobileprovision>"
        }

        let plistText = String(profileText[plistStart.lowerBound..<plistEnd.upperBound])
        guard let plistData = plistText.data(using: .isoLatin1) else {
            return "<could not re-encode embedded plist>"
        }

        do {
            guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
                return "<embedded.mobileprovision plist was not a dictionary>"
            }
            guard let entitlements = plist["Entitlements"] as? [String: Any] else {
                return "<no Entitlements dictionary in embedded.mobileprovision>"
            }
            guard let apsEnvironment = entitlements["aps-environment"] as? String else {
                return "<no aps-environment key in embedded.mobileprovision Entitlements>"
            }
            return apsEnvironment
        } catch {
            return "<failed to parse embedded.mobileprovision plist: \(error.localizedDescription)>"
        }
    }

    private static func logPersistentStoreFailure(_ error: NSError, description: NSPersistentStoreDescription) {
        print("❌ [Persistence] Failed to load store url=\(description.url?.absoluteString ?? "<nil>") configuration=\(description.configuration ?? "default")")
        print("❌ [Persistence] domain=\(error.domain) code=\(error.code) userInfo=\(error.userInfo)")
        logStoreMetadata(at: description.url)
        #if DEBUG
        print("🧪 [Persistence] Development-only recovery: delete the app, or use the debug reset button in StoreRecoveryView. Production builds must not silently delete user stores.")
        #endif
    }

    private static func logStoreMetadata(at url: URL?) {
        guard let url else { return }
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
            let configuration = metadata[NSStoreModelVersionIdentifiersKey] ?? "<no model identifiers>"
            print("ℹ️ [Persistence] metadata url=\(url.lastPathComponent) modelVersionIdentifiers=\(configuration)")
        } catch {
            print("ℹ️ [Persistence] no readable metadata at \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    #if DEBUG
    /// Phase 1 (CKSyncEngine migration): disabled, not deleted. `container` is now a plain
    /// `NSPersistentContainer`, which has no `initializeCloudKitSchema(options:)` — that API
    /// belonged to `NSPersistentCloudKitContainer` mirroring. Left as a clear runtime error
    /// (rather than removing the function) so `CloudKitStoreDiagnosticsView.swift:111`'s call
    /// site keeps compiling and shows an honest message instead of silently doing nothing.
    func initializeDevelopmentCloudKitSchema() throws {
        print("🧪 [CloudKitSchemaInit] Disabled in Phase 1 — container is a plain NSPersistentContainer, no CloudKit schema to initialize this way anymore.")
        throw NSError(
            domain: "PersistenceController",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "CloudKit schema initialization is disabled in Phase 1 (CKSyncEngine migration removed NSPersistentCloudKitContainer mirroring)."]
        )
    }

    static func resetDevelopmentStores() throws {
        let urls = storeURLs()
        let fileManager = FileManager.default
        for baseURL in [urls.privateURL, urls.sharedURL] {
            for suffix in ["", "-shm", "-wal"] {
                let url = suffix.isEmpty ? baseURL : URL(fileURLWithPath: baseURL.path + suffix)
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                    print("🧪 [Persistence] Removed development store file \(url.path)")
                }
            }
        }
        SelectionStore.clearAll()
        SharedHouseholdLeaveStore.clearAll()
    }
    #endif
}
