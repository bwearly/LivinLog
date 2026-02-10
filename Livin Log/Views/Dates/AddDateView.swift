//
//  AddDateView.swift
//  Livin Log
//
//  Created by Blake Early on 2/9/26.
//
import SwiftUI
 
struct AddDateView: View {
    let household: Household

    var body: some View {
        AddEditEventView(household: household)
    }
}
