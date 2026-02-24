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
    private let cloudKitContainerId = "iCloud.com.blakeearly.livinlog"

    init(container: NSPersistentCloudKitContainer) {
        self.container = container
    }

    func start() async {
        route = .loading

        // 1) iCloud available?
        let status = await fetchICloudStatus()
        guard status == .available else {
            route = .iCloudRequired
            household = nil
            member = nil
            return
        }

        // 2) Load the "active" household from either private OR shared store.
        //    (Important for recipients of CloudKit shares.)
        if let h = fetchMostRecentHousehold() {
            household = h

            // 3) Ensure we have a member object if your UI expects one.
            //    For shared households, recipients often won't have a member row yet.
            member = ensureMemberExists(for: h)

            route = .main
        } else {
            household = nil
            member = nil
            route = .onboarding
        }
    }

    // MARK: - Household selection

    /// Fetches the most recent Household from Core Data.
    /// By default this searches across *all* persistent stores (private + shared),
    /// as long as you do not restrict `affectedStores`.
    private func fetchMostRecentHousehold() -> Household? {
        let ctx = container.viewContext

        let req = Household.fetchRequest()
        req.fetchLimit = 1

        // Prefer newest if createdAt exists, otherwise you'll still get "some" household.
        req.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: false)
        ]

        do {
            return try ctx.fetch(req).first as? Household
        } catch {
            print("❌ fetchMostRecentHousehold failed:", error)
            return nil
        }
    }

    // MARK: - Member helper

    /// Creates a HouseholdMember for this household if one doesn't exist.
    /// If your HouseholdMember model uses different fields, update the marked section.
    private func ensureMemberExists(for household: Household) -> HouseholdMember? {
        let ctx = container.viewContext

        // If you have a stable identifier for "this device/user" you can use that here.
        // For now, we just ensure there's at least one member linked to the household.
        let req = HouseholdMember.fetchRequest()
        req.fetchLimit = 1
        req.predicate = NSPredicate(format: "household == %@", household)

        do {
            if let existing = try ctx.fetch(req).first as? HouseholdMember {
                return existing
            }

            // No member yet — create one so UI logic doesn't fail on recipients.
            let m = HouseholdMember(context: ctx)

            // ✅ Adjust these fields to match your model.
            // If you don't have these properties, remove them.
            m.id = UUID()
            m.createdAt = Date()
            m.household = household

            try ctx.save()
            return m
        } catch {
            print("❌ ensureMemberExists failed:", error)
            ctx.rollback()
            return nil
        }
    }

    // MARK: - iCloud

    private func fetchICloudStatus() async -> CKAccountStatus {
        await withCheckedContinuation { continuation in
            CKContainer(identifier: cloudKitContainerId).accountStatus { status, _ in
                continuation.resume(returning: status)
            }
        }
    }
}
