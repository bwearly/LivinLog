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

    init(container: NSPersistentCloudKitContainer) {
        self.container = container
    }

    func start() async {
        route = .loading

        // 1) iCloud available?
        let status = await fetchICloudStatus()
        guard status == .available else {
            route = .iCloudRequired
            return
        }

        // 2) Do we already have a Household in our local store?
        if hasAnyHousehold() {
            route = .main
        } else {
            route = .onboarding
        }
    }

    private func hasAnyHousehold() -> Bool {
        let ctx = container.viewContext
        let req = Household.fetchRequest()
        req.fetchLimit = 1
        do {
            return try ctx.count(for: req) > 0
        } catch {
            return false
        }
    }

    private func fetchICloudStatus() async -> CKAccountStatus {
        await withCheckedContinuation { continuation in
            CKContainer(identifier: "iCloud.com.blakeearly.keeply").accountStatus { status, _ in
                continuation.resume(returning: status)
            }
        }
    }
}
