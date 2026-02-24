//
//  Persistence.swift
//  Livin Log
//

import CoreData
import CloudKit

struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer

    /// The private (owner) store.
    let privateStore: NSPersistentStore

    /// The shared store (where accepted shares land on recipients).
    let sharedStore: NSPersistentStore

    init(inMemory: Bool = false) {
        let container = NSPersistentCloudKitContainer(name: "LivinLog")
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "<unknown>"
        print("ℹ️ PersistenceController init bundleIdentifier=\(bundleIdentifier) persistentContainerName=\(container.name)")

        // Two stores are required for Core Data + CloudKit sharing:
        // - Private: the owner's database
        // - Shared:  the recipient's shared database
        let storeDirectory = NSPersistentContainer.defaultDirectoryURL()

        // IMPORTANT: keep the private store filename stable so existing on-device data
        // continues to load after introducing the shared store.
        //
        // Historically the app used a single default store; that typically results in a
        // `LivinLog.sqlite` filename. If we switch filenames, the app will look like it
        // "lost" data because it is reading a new empty file.
        let privateURL = storeDirectory.appendingPathComponent("LivinLog.sqlite")
        let sharedURL  = storeDirectory.appendingPathComponent("LivinLog-shared.sqlite")

        let privateDesc = NSPersistentStoreDescription(url: privateURL)
        let sharedDesc  = NSPersistentStoreDescription(url: sharedURL)

        if inMemory {
            privateDesc.url = URL(fileURLWithPath: "/dev/null")
            sharedDesc.url  = URL(fileURLWithPath: "/dev/null")
        }

        let containerId = "iCloud.com.blakeearly.livinlog"
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
        }

        container.persistentStoreDescriptions = [privateDesc, sharedDesc]

        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }

            let scope = description.cloudKitContainerOptions?.databaseScope
            let scopeLabel: String
            switch scope {
            case .private: scopeLabel = "private"
            case .shared: scopeLabel = "shared"
            case .public: scopeLabel = "public"
            default: scopeLabel = "unknown"
            }
            print("ℹ️ Loaded persistent store url=\(description.url?.absoluteString ?? "<nil>") scope=\(scopeLabel) ckContainer=\(description.cloudKitContainerOptions?.containerIdentifier ?? "<nil>")")
        }

        // Resolve stores by URL from the coordinator after load.
        func store(matching url: URL) -> NSPersistentStore? {
            container.persistentStoreCoordinator.persistentStores.first { $0.url == url }
        }

        guard let p = store(matching: privateURL),
              let s = store(matching: sharedURL) else {
            fatalError("Failed to resolve private/shared stores after loading.")
        }

        self.container = container
        self.privateStore = p
        self.sharedStore = s

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
}
