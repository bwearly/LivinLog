//
//  ContentView.swift
//  SyncSpike
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var sync: SyncController
    @State private var newItemTitle = ""
    @State private var isPresentingShare = false
    @State private var isCreatingHousehold = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let zoneID = sync.householdZoneID {
                        LabeledContent("Household zone", value: zoneID.zoneName)
                        LabeledContent("Role", value: sync.householdIsOwnedLocally ? "Owner" : "Participant")
                    } else {
                        Text("No household yet")
                            .foregroundStyle(.secondary)
                    }
                    if let lastError = sync.lastError {
                        Text("Last error: \(lastError)")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                } header: {
                    Text("Status")
                }

                Section {
                    ForEach(sync.items) { item in
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text("by \(item.createdBy)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Items (\(sync.items.count))")
                }
            }
            .navigationTitle("SyncSpike")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if sync.householdZoneID == nil {
                        Button {
                            isCreatingHousehold = true
                            Task {
                                await sync.createHousehold()
                                isCreatingHousehold = false
                            }
                        } label: {
                            if isCreatingHousehold {
                                ProgressView()
                            } else {
                                Text("Create household")
                            }
                        }
                        .disabled(isCreatingHousehold)
                    } else if sync.householdIsOwnedLocally {
                        Button("Invite") {
                            isPresentingShare = true
                        }
                        .disabled(sync.currentShare == nil)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if sync.householdZoneID != nil {
                    HStack {
                        TextField("New item title", text: $newItemTitle)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            let title = newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !title.isEmpty else { return }
                            sync.addItem(title: title)
                            newItemTitle = ""
                        }
                        .disabled(newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding()
                    .background(.bar)
                }
            }
            .sheet(isPresented: $isPresentingShare) {
                if let share = sync.currentShare {
                    CloudSharingView(share: share, container: sync.container)
                }
            }
        }
    }
}
