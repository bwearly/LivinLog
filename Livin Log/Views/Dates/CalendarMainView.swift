//
//  CalendarMainView.swift
//  Livin Log
//
//  Created by Blake Early on 2/10/26.
//

import SwiftUI
import CoreData

struct CalendarMainView: View {
    enum DisplayMode: String, CaseIterable, Identifiable {
        case calendar = "Calendar"
        case list = "List"

        var id: String { rawValue }
    }

    enum ActiveSheet: Identifiable {
        case add(prefilledMonth: Int16, prefilledDay: Int16)
        case dayEvents(CalendarDaySelection)

        var id: String {
            switch self {
            case let .add(month, day):
                return "add-\(month)-\(day)"
            case let .dayEvents(selection):
                return "day-\(selection.id)"
            }
        }
    }

    private let household: Household

    @FetchRequest private var events: FetchedResults<LLCalendarEvent>

    @State private var mode: DisplayMode = .calendar
    @State private var activeSheet: ActiveSheet?

    private let displayYear: Int
    private let calendar = Calendar.current

    init(
        household: Household,
        displayYear: Int = Calendar.current.component(.year, from: Date())
    ) {
        self.household = household
        self.displayYear = displayYear

        _events = FetchRequest(
            sortDescriptors: [
                NSSortDescriptor(keyPath: \\LLCalendarEvent.month, ascending: true),
                NSSortDescriptor(keyPath: \\LLCalendarEvent.day, ascending: true),
                NSSortDescriptor(keyPath: \\LLCalendarEvent.createdAt, ascending: true)
            ],
            predicate: NSPredicate(format: "household == %@", household),
            animation: .default
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if mode == .calendar {
                    calendarBody
                } else {
                    EventListView(events: Array(events), household: household)
                }
            }
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("View", selection: $mode) {
                        ForEach(DisplayMode.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        activeSheet = .add(
                            prefilledMonth: Int16(calendar.component(.month, from: Date())),
                            prefilledDay: Int16(calendar.component(.day, from: Date()))
                        )
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Event")
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case let .add(month, day):
                    AddEditEventView(
                        household: household,
                        prefilledMonth: month,
                        prefilledDay: day
                    )
                case let .dayEvents(selection):
                    DayEventsSheet(
                        household: household,
                        month: selection.month,
                        day: selection.day,
                        events: eventsFor(month: selection.month, day: selection.day)
                    )
                }
            }
        }
    }

    private var calendarBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 20) {
                    ForEach(1...12, id: \.self) { month in
                        MonthSectionView(
                            month: month,
                            displayYear: displayYear,
                            hasEventsForDay: { day in
                                !eventsFor(month: month, day: day).isEmpty
                            },
                            onDayTapped: { day in
                                activeSheet = .dayEvents(.init(month: month, day: day))
                            }
                        )
                        .id(month)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            .onAppear {
                let currentMonth = calendar.component(.month, from: Date())
                DispatchQueue.main.async {
                    proxy.scrollTo(currentMonth, anchor: .top)
                }
            }
        }
    }

    private func eventsFor(month: Int, day: Int) -> [LLCalendarEvent] {
        events
            .filter { Int($0.month) == month && Int($0.day) == day }
            .sorted { $0.createdAtValue < $1.createdAtValue }
    }
}

struct CalendarDaySelection: Identifiable {
    let month: Int
    let day: Int

    var id: String { "\(month)-\(day)" }
}
