import SwiftUI
import CoreData

struct QuoteFiltersSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var filters: QuoteFilterState
    let children: [LLChild]
    let recentSpeakers: [String]
    let allYears: Set<Int>
    let onManageChildren: () -> Void

    var body: some View {
        Form {
            Section("Speaker") {
                TextField("Speaker contains", text: $filters.speakerQuery)

                if !recentSpeakers.isEmpty {
                    Picker("Recent speaker", selection: $filters.selectedRecentSpeaker) {
                        Text("Any").tag(Optional<String>.none)
                        ForEach(recentSpeakers, id: \.self) { speaker in
                            Text(speaker).tag(Optional(speaker))
                        }
                    }
                }
            }

            Section("Child") {
                Picker("Child", selection: $filters.selectedChildID) {
                    Text("Any").tag(Optional<NSManagedObjectID>.none)
                    ForEach(children, id: \.objectID) { child in
                        Text(child.nameValue).tag(Optional(child.objectID))
                    }
                }

                if filters.selectedChildID != nil {
                    Picker("Age range", selection: $filters.selectedAgeRange) {
                        Text("Any").tag(Optional<QuoteAgeRange>.none)
                        ForEach(QuoteAgeRange.allCases) { range in
                            Text(range.rawValue).tag(Optional(range))
                        }
                    }
                }

                Button("Manage Children") {
                    onManageChildren()
                }
            }

            Section("Year") {
                Picker("Year", selection: $filters.selectedYear) {
                    Text("Any").tag(Optional<Int>.none)
                    ForEach(Array(allYears).sorted(by: >), id: \.self) { year in
                        Text(String(year)).tag(Optional(year))
                    }
                }
            }

            Section("Sort") {
                Picker("Sort", selection: $filters.sortOption) {
                    ForEach(QuoteSortOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            }

            Section {
                Button("Reset Filters") {
                    filters = QuoteFilterState()
                }
            }
        }
        .navigationTitle("Quote Filters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}
