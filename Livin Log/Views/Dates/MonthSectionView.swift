//
//  MonthSectionview.swift
//  Livin Log
//
//  Created by Blake Early on 2/10/26.
//

import SwiftUI

struct MonthSectionView: View {
    let month: Int
    let displayYear: Int
    let hasEventsForDay: (Int) -> Bool
    let onDayTapped: (Int) -> Void

    private var calendar: Calendar {
        var cal = Calendar.current
        return cal
    }

    private var monthDate: Date {
        var components = DateComponents()
        components.year = displayYear
        components.month = month
        components.day = 1
        return calendar.date(from: components) ?? Date()
    }

    private var daysInMonth: Int {
        calendar.range(of: .day, in: .month, for: monthDate)?.count ?? 30
    }

    private var leadingBlankDays: Int {
        // weekday and firstWeekday are 1...7
        let weekday = calendar.component(.weekday, from: monthDate)
        let first = calendar.firstWeekday
        return (weekday - first + 7) % 7
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(monthDate.formatted(.dateTime.month(.wide)))
                .font(.title3.weight(.semibold))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
                // Weekday headers
                ForEach(Array(orderedWeekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.65))
                        .frame(maxWidth: .infinity)
                        .frame(height: 18)
                }

                // Day cells (leading blanks + 1...daysInMonth)
                ForEach(Array(dayCells().enumerated()), id: \.offset) { _, cellDay in
                    if let day = cellDay {
                        Button {
                            onDayTapped(day)
                        } label: {
                            ZStack {
                                Text("\(day)")
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                                VStack {
                                    Spacer(minLength: 0)
                                    Circle()
                                        .fill(hasEventsForDay(day) ? Color.accentColor : .clear)
                                        .frame(width: 5, height: 5)
                                        .padding(.bottom, 4)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(isToday(day: day) ? Color.accentColor.opacity(0.18) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func dayCells() -> [Int?] {
        // `leadingBlankDays` empty slots, then day numbers 1...daysInMonth
        let blanks = Array(repeating: Optional<Int>.none, count: leadingBlankDays)
        let days = (1...daysInMonth).map { Optional($0) }
        return blanks + days
    }

    private func orderedWeekdaySymbols() -> [String] {
        // Locale-aware weekday symbols in the correct order.
        // We rotate based on firstWeekday and then normalize each symbol to a single character
        // so the grid never clips (e.g., no "Th" / "Sat" width issues).
        let base = calendar.shortWeekdaySymbols // e.g., ["Sun", "Mon", ...]
        let firstIndex = max(0, min(calendar.firstWeekday - 1, base.count - 1))
        let rotated = Array(base[firstIndex...] + base[..<firstIndex])
        return rotated.map { symbol in
            // Take the first grapheme cluster (works for "Sun" and also non-Latin locales like "木")
            String(symbol.prefix(1))
        }
    }

    private func isToday(day: Int) -> Bool {
        let now = Date()
        let nowMonth = calendar.component(.month, from: now)
        let nowDay = calendar.component(.day, from: now)
        let nowYear = calendar.component(.year, from: now)
        return nowYear == displayYear && nowMonth == month && nowDay == day
    }
}
