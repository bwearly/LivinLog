//
//  MemberStatus.swift
//  Livin Log
//
//  Phase 3b: the member status label shown in the onboarding roster and Settings > Members,
//  derived purely from HouseholdMember's own fields -- no HouseholdMembership lookups. Replaces
//  the old "Member"/"Invite pending"/"View only" labels, which were HouseholdMembership-derived
//  and had been silently dead since Phase 3a (HouseholdMembership stopped being populated).

import CoreData

struct MemberStatus {
    enum Kind {
        case you
        case joined
        case invited
        case notInvited
        case noIPhone
    }

    let kind: Kind
    /// Shown as a separate "Leader" tag alongside `kind`'s label -- independent of `kind` so a
    /// leader's row reads "Joined · Leader" (or "You · Leader") rather than needing a sixth case.
    let isLeader: Bool

    var label: String {
        switch kind {
        case .you: return "You"
        case .joined: return "Joined"
        case .invited: return "Invited"
        case .notInvited: return "Not invited"
        case .noIPhone: return "No iPhone"
        }
    }

    static func resolve(for member: HouseholdMember, currentUserRecordName: String?) -> MemberStatus {
        let linked = (member.value(forKey: "linkedUserRecordName") as? String).flatMap { $0.isEmpty ? nil : $0 }
        let hasOwnIPhone = (member.value(forKey: "hasOwnIPhone") as? Bool) ?? false
        let invitedAt = member.value(forKey: "invitedAt") as? Date
        let isLeader = (member.value(forKey: "role") as? String) == "leader"

        if let linked {
            let kind: Kind = (linked == currentUserRecordName) ? .you : .joined
            return MemberStatus(kind: kind, isLeader: isLeader)
        }
        if hasOwnIPhone {
            return MemberStatus(kind: invitedAt != nil ? .invited : .notInvited, isLeader: isLeader)
        }
        return MemberStatus(kind: .noIPhone, isLeader: isLeader)
    }

    /// Eligible for the Invite/Resend action: has their own iPhone, and isn't already linked.
    static func isInviteEligible(_ member: HouseholdMember) -> Bool {
        let linked = (member.value(forKey: "linkedUserRecordName") as? String).flatMap { $0.isEmpty ? nil : $0 }
        let hasOwnIPhone = (member.value(forKey: "hasOwnIPhone") as? Bool) ?? false
        return linked == nil && hasOwnIPhone
    }
}
