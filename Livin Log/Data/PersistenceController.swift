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

struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer

    /// The private (owner) store.
    let privateStore: NSPersistentStore!

    /// The shared store (where accepted shares land on recipients).
    let sharedStore: NSPersistentStore!

    /// Non-nil when Core Data/CloudKit stores could not be opened. The app should
    /// render recovery UI instead of touching the managed object context.
    let loadError: PersistenceLoadError?

    var isLoaded: Bool { loadError == nil }

    private static let containerId = "iCloud.com.blakeearly.livinlog"

    private static func storeURLs() -> (privateURL: URL, sharedURL: URL) {
        let storeDirectory = NSPersistentContainer.defaultDirectoryURL()
        return (
            storeDirectory.appendingPathComponent("LivinLog.sqlite"),
            storeDirectory.appendingPathComponent("LivinLog-shared.sqlite")
        )
    }

    init(inMemory: Bool = false) {
        let container = NSPersistentCloudKitContainer(name: "LivinLog")
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "<unknown>"
        print("ℹ️ PersistenceController init bundleIdentifier=\(bundleIdentifier) persistentContainerName=\(container.name)")

        // Two stores are required for Core Data + CloudKit sharing:
        // - Private: the owner's database
        // - Shared:  the recipient's shared database
        let urls = Self.storeURLs()
        let privateURL = urls.privateURL
        let sharedURL = urls.sharedURL

        let privateDesc = NSPersistentStoreDescription(url: privateURL)
        let sharedDesc  = NSPersistentStoreDescription(url: sharedURL)

        // Keep both stores on the model's default configuration. A previous build or a
        // future refactor that writes one store with a named configuration and then opens
        // it with another is what produces Core Data's "model configuration ...
        // incompatible" launch failure. This app does not define named model
        // configurations, so be explicit and log it.
        privateDesc.configuration = nil
        sharedDesc.configuration = nil

        if inMemory {
            privateDesc.url = URL(fileURLWithPath: "/dev/null")
            sharedDesc.url  = URL(fileURLWithPath: "/dev/null")
        }

        let containerId = Self.containerId
        print("ℹ️ PersistenceController CloudKit containerIdentifier=\(containerId)")

        // Private scope
        let privateOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerId)
        privateOptions.databaseScope = .private
        privateDesc.cloudKitContainerOptions = privateOptions

        // Shared scope
        let sharedOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerId)
        sharedOptions.databaseScope = .shared
        sharedDesc.cloudKitContainerOptions = sharedOptions

        // Common store options
        for desc in [privateDesc, sharedDesc] {
            desc.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            desc.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
            desc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            desc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            desc.shouldMigrateStoreAutomatically = true
            desc.shouldInferMappingModelAutomatically = true
        }

        container.persistentStoreDescriptions = [privateDesc, sharedDesc]

        Self.logLoadedModelDiagnostics(container: container, reason: "before loadPersistentStores")

        var capturedLoadError: PersistenceLoadError?
        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                Self.logPersistentStoreFailure(error, description: description)
                capturedLoadError = PersistenceLoadError(error: error, description: description)
                return
            }

            let scope = description.cloudKitContainerOptions?.databaseScope
            let scopeLabel: String
            switch scope {
            case .private: scopeLabel = "private"
            case .shared: scopeLabel = "shared"
            case .public: scopeLabel = "public"
            default: scopeLabel = "unknown"
            }
            print("ℹ️ Loaded persistent store url=\(description.url?.absoluteString ?? "<nil>") scope=\(scopeLabel) configuration=\(description.configuration ?? "default") migrate=\(description.shouldMigrateStoreAutomatically) infer=\(description.shouldInferMappingModelAutomatically) ckContainer=\(description.cloudKitContainerOptions?.containerIdentifier ?? "<nil>")")
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

        // Resolve stores by URL from the coordinator after load.
        func store(matching url: URL) -> NSPersistentStore? {
            container.persistentStoreCoordinator.persistentStores.first { $0.url == url }
        }

        guard let p = store(matching: privateURL),
              let s = store(matching: sharedURL) else {
            let error = NSError(
                domain: "PersistenceController",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to resolve private/shared stores after loading."]
            )
            let description = NSPersistentStoreDescription(url: privateURL)
            Self.logPersistentStoreFailure(error, description: description)
            self.privateStore = nil
            self.sharedStore = nil
            self.loadError = PersistenceLoadError(error: error, description: description)
            return
        }

        self.privateStore = p
        self.sharedStore = s
        self.loadError = nil

        Self.logLoadedModelDiagnostics(container: container, reason: "after loadPersistentStores")

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }


    private static func logLoadedModelDiagnostics(container: NSPersistentCloudKitContainer, reason: String) {
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
