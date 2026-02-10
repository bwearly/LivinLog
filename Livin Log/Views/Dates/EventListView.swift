//
//  EventListView.swift
//  Livin Log
//
//  Created by Blake Early on 2/10/26.
//

import SwiftUI

struct EventListView: View {
    let events: [LLCalendarEvent]
    let household: Household

    @State private var editingEvent: LLCalendarEvent?

    var grouped: [(month: Int, dayGroups: [(day: Int, events: [LLCalendarEvent])])] {
        let byMonth = Dictionary(grouping: events) { Int($0.month) }

        return byMonth
            .keys
            .sorted()
            .map { month in
                let monthEvents = byMonth[month] ?? []
                let byDay = Dictionary(grouping: monthEvents) { Int($0.day) }
                let dayGroups = byDay.keys.sorted().map { day in
                    (day: day, events: (byDay[day] ?? []).sorted { $0.createdAtValue < $1.createdAtValue })
                }
                return (month: month, dayGroups: dayGroups)
            }
    }

    var body: some View {
        List {
            if grouped.isEmpty {
                ContentUnavailableView("No Events Yet", systemImage: "calendar")
            } else {
                ForEach(grouped, id: \.month) { monthGroup in
                    Section(monthName(monthGroup.month)) {
                        ForEach(monthGroup.dayGroups, id: \.day) { dayGroup in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(monthName(monthGroup.month, short: true)) \(dayGroup.day)")
                                    .font(.headline)

                                ForEach(dayGroup.events) { event in
                                    Button {
                                        editingEvent = event
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(event.nameText)
                                                .foregroundStyle(.primary)
                                            Text(event.secondaryInfo)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .sheet(item: $editingEvent) { event in
            AddEditEventView(household: household, editingEvent: event)
        }
    }

    private func monthName(_ month: Int, short: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        if short {
            return formatter.shortMonthSymbols[max(0, min(month - 1, formatter.shortMonthSymbols.count - 1))]
        }
        return formatter.monthSymbols[max(0, min(month - 1, formatter.monthSymbols.count - 1))]
    }
}
