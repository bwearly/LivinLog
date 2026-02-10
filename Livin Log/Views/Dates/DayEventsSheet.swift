//
//  DayEventsSheet.swift
//  Livin Log
//
//  Created by Blake Early on 2/10/26.
//

import SwiftUI

struct DayEventsSheet: View {
    let household: Household
    let month: Int
    let day: Int
    let events: [LLCalendarEvent]

    enum ActiveSheet: Identifiable {
        case add
        case edit(LLCalendarEvent)

        var id: String {
            switch self {
            case .add:
                return "add"
            case let .edit(event):
                return "edit-\(event.objectID.uriRepresentation().absoluteString)"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?

    var body: some View {
        NavigationStack {
            List {
                if events.isEmpty {
                    ContentUnavailableView("No Events", systemImage: "calendar.badge.exclamationmark", description: Text("No events for this date yet."))
                } else {
                    ForEach(events) { event in
                        Button {
                            activeSheet = .edit(event)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.nameText)
                                    .font(.headline)
                                Text(event.secondaryInfo)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("\(monthName(month)) \(day)")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Event") {
                        activeSheet = .add
                    }
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .add:
                    AddEditEventView(household: household, prefilledMonth: Int16(month), prefilledDay: Int16(day))
                case let .edit(event):
                    AddEditEventView(household: household, editingEvent: event)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        return formatter.monthSymbols[max(0, min(month - 1, formatter.monthSymbols.count - 1))]
    }
}
