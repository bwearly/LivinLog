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

    private let calendar = Calendar.current
    private let weekdaySymbols = ["S", "M", "T", "W", "T", "F", "S"]

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
        let weekday = calendar.component(.weekday, from: monthDate)
        return weekday - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(monthDate.formatted(.dateTime.month(.wide)))
                .font(.title3.weight(.semibold))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(0..<leadingBlankDays, id: \.self) { _ in
                    Color.clear
                        .frame(height: 34)
                }

                ForEach(1...daysInMonth, id: \.self) { day in
                    Button {
                        onDayTapped(day)
                    } label: {
                        VStack(spacing: 3) {
                            Text("\(day)")
                                .font(.subheadline)
                                .foregroundStyle(.primary)

                            Circle()
                                .fill(hasEventsForDay(day) ? Color.accentColor : .clear)
                                .frame(width: 5, height: 5)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(isToday(day: day) ? Color.accentColor.opacity(0.18) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func isToday(day: Int) -> Bool {
        let now = Date()
        let nowMonth = calendar.component(.month, from: now)
        let nowDay = calendar.component(.day, from: now)
        let nowYear = calendar.component(.year, from: now)
        return nowYear == displayYear && nowMonth == month && nowDay == day
    }
}
