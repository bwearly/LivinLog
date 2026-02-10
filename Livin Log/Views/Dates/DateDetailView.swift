//
//  DateDetailView.swift
//  Livin Log
//
//  Created by Blake Early on 2/9/26.
//

import SwiftUI
 
struct DateDetailView: View {
    let household: Household

    var body: some View {
        CalendarMainView(household: household)
    }
}
