//
//  SetupDiagnostics.swift
//  Livin Log
//
//  Temporary production-safe diagnostics for setup/sign-in routing.
//

import Foundation
import CoreData

@MainActor
enum SetupDiagnostics {
    static func logOnboardingScreen(
        isSignedIn: Bool,
        appUser: AppUser?,
        household: Household?,
        member: HouseholdMember?,
        membership: HouseholdMembership?,
        candidateMembershipCount: Int,
        isInviteFlow: Bool,
        context: NSManagedObjectContext
    ) {
        let counts = entityCounts(context: context)
        log(
            "onboarding screen " +
            "bundle=\(bundleIdentifier) " +
            "version=\(version) build=\(build) config=\(buildConfiguration) " +
            "platform=\(platform) " +
            "signInWithAppleUIEnabled=\(!isSignedIn) " +
            "authenticatedWithApple=\(isSignedIn) " +
            "usesMockIdentity=false " +
            "inviteFlow=\(isInviteFlow) " +
            "appUserExists=\(appUser != nil) appUser=\(describeAppUser(appUser)) appUserCount=\(counts.appUsers) " +
            "householdExists=\(household != nil) household=\(describeHousehold(household)) householdCount=\(counts.households) " +
            "currentMemberExists=\(member != nil) member=\(describeMember(member)) memberCount=\(counts.members) " +
            "currentMembershipExists=\(membership != nil) membershipCount=\(counts.memberships) " +
            "candidateMembershipCount=\(candidateMembershipCount)"
        )
    }

    static func logRouteDecision(
        route: String,
        reason: String,
        appUser: AppUser?,
        household: Household?,
        member: HouseholdMember?,
        membership: HouseholdMembership?,
        candidateMembershipCount: Int,
        context: NSManagedObjectContext
    ) {
        let counts = entityCounts(context: context)
        log(
            "route decision route=\(route) reason=\(reason) " +
            "bundle=\(bundleIdentifier) config=\(buildConfiguration) platform=\(platform) " +
            "authenticatedWithApple=\(appUser != nil) usesMockIdentity=false " +
            "appUserExists=\(appUser != nil) appUser=\(describeAppUser(appUser)) appUserCount=\(counts.appUsers) " +
            "householdExists=\(household != nil) household=\(describeHousehold(household)) householdCount=\(counts.households) " +
            "currentMemberExists=\(member != nil) member=\(describeMember(member)) memberCount=\(counts.members) " +
            "currentMembershipExists=\(membership != nil) membershipCount=\(counts.memberships) " +
            "candidateMembershipCount=\(candidateMembershipCount)"
        )
    }

    private static func entityCounts(context: NSManagedObjectContext) -> (appUsers: Int, households: Int, members: Int, memberships: Int) {
        (
            count("AppUser", context: context),
            count("Household", context: context),
            count("HouseholdMember", context: context),
            count("HouseholdMembership", context: context)
        )
    }

    private static func count(_ entityName: String, context: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        request.includesPendingChanges = true
        return (try? context.count(for: request)) ?? -1
    }

    private static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "unknown" }
    private static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown" }
    private static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown" }

    private static var buildConfiguration: String {
        #if DEBUG
        return "DEBUG"
        #else
        return "RELEASE"
        #endif
    }

    private static var platform: String {
        #if targetEnvironment(simulator)
        return "simulator"
        #else
        return "device"
        #endif
    }

    private static func describeAppUser(_ user: AppUser?) -> String {
        guard let user else { return "nil" }
        return "provider=\(user.authProvider ?? "nil") subjectHash=\((user.providerSubject ?? "nil").hashValue)"
    }

    private static func describeHousehold(_ household: Household?) -> String {
        guard let household else { return "nil" }
        return "id=\(household.id?.uuidString ?? "nil") name=\(household.name ?? "nil")"
    }

    private static func describeMember(_ member: HouseholdMember?) -> String {
        guard let member else { return "nil" }
        let claimed = member.value(forKey: "claimedByAppUserId") as? String
        return "id=\(member.id?.uuidString ?? "nil") name=\(member.displayName ?? "nil") claimed=\(claimed?.isEmpty == false)"
    }

    private static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("🩺 [SetupDiagnostics \(timestamp)] \(message)")
    }
}
