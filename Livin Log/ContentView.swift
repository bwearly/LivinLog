//
//  ContentView.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//

import SwiftUI
import CoreData

struct ContentView: View {
    let household: Household?
    let member: HouseholdMember?

    var body: some View {
        HomeDashboardView(household: household, member: member)
    }
}
