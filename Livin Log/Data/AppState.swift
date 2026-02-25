//
//  AppState.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//

import Foundation
import CloudKit
import CoreData
import Combine

extension Notification.Name {
    static let didAcceptCloudKitShare = Notification.Name("didAcceptCloudKitShare")
}

@MainActor
final class AppState: ObservableObject {

    enum Route {
        case loading
        case iCloudRequired
        case onboarding
        case main
    }

    @Published var route: Route = .loading
    @Published var household: Household?
    @Published var member: HouseholdMember?

    private let container: NSPersistentCloudKitContainer
    private let cloudKitContainerId = "iCloud.com.blakeearly.livinlog"
    private var cancellables = Set<AnyCancellable>()

    init(container: NSPersistentCloudKitContainer) {
        self.container = container
        observeShareAcceptanceAndStoreChanges()
    }

    func start() async {
        route = .loading

        let status = await fetchICloudStatus()
        guard status == .available else {
            route = .iCloudRequired
            household = nil
            member = nil
            return
        }

        guard hasAnyHousehold(), let h = fetchMostRecentHousehold() else {
            household = nil
            member = nil
            route = .onboarding
            return
        }

        household = h
        member = ensureMemberExists(for: h)
        route = .main
    }

    private func observeShareAcceptanceAndStoreChanges() {
        NotificationCenter.default.publisher(for: .didAcceptCloudKitShare)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.start()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator
        )
        .sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.route == .onboarding {
                    await self.start()
                }
            }
        }
        .store(in: &cancellables)
    }

    private func hasAnyHousehold() -> Bool {
        let ctx = container.viewContext
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "Household")
        req.fetchLimit = 1
        req.includesPendingChanges = true
        req.affectedStores = container.persistentStoreCoordinator.persistentStores

        do {
            return try ctx.count(for: req) > 0
        } catch {
            print("❌ hasAnyHousehold failed: \(error)")
            return false
        }
    }

    private func fetchMostRecentHousehold() -> Household? {
        let ctx = container.viewContext

        let req = Household.fetchRequest()
        req.fetchLimit = 1
        req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        req.affectedStores = container.persistentStoreCoordinator.persistentStores

        do {
            return try ctx.fetch(req).first as? Household
        } catch {
            print("❌ fetchMostRecentHousehold failed: \(error)")
            return nil
        }
    }

    private func ensureMemberExists(for household: Household) -> HouseholdMember? {
        let ctx = container.viewContext

        let req = HouseholdMember.fetchRequest()
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "household == %@", household)

        do {
            if let existing = try ctx.fetch(req).first as? HouseholdMember {
                return existing
            }

            let m = HouseholdMember(context: ctx)
            m.id = UUID()
            m.createdAt = Date()
            m.household = household

            try ctx.save()
            return m
        } catch {
            print("❌ ensureMemberExists failed: \(error)")
            ctx.rollback()
            return nil
        }
    }

    private func fetchICloudStatus() async -> CKAccountStatus {
        await withCheckedContinuation { continuation in
            CKContainer(identifier: cloudKitContainerId).accountStatus { status, _ in
                continuation.resume(returning: status)
            }
        }
    }
}
