//
//  AddEditEventView.swift
//  Livin Log
//
//  Created by Blake Early on 2/10/26.
//

import SwiftUI
import CoreData

struct AddEditEventView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    let household: Household
    let editingEvent: LLCalendarEvent?

    @State private var name = ""
    @State private var month: Int16
    @State private var day: Int16
    @State private var yearText = ""
    @State private var tag = "Other"
    @State private var notificationsEnabled = true

    private let tags = ["Birthday", "Anniversary", "Family", "Milestone", "Travel", "Medical", "School", "Work", "Other"]

    init(household: Household, editingEvent: LLCalendarEvent? = nil, prefilledMonth: Int16? = nil, prefilledDay: Int16? = nil) {
        self.household = household
        self.editingEvent = editingEvent

        let today = Date()
        let calendar = Calendar.current

        _month = State(initialValue: prefilledMonth ?? Int16(calendar.component(.month, from: today)))
        _day = State(initialValue: prefilledDay ?? Int16(calendar.component(.day, from: today)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Event Name", text: $name)

                    Picker("Month", selection: $month) {
                        ForEach(1...12, id: \.self) { month in
                            Text(monthName(month)).tag(Int16(month))
                        }
                    }

                    Picker("Day", selection: $day) {
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day)").tag(Int16(day))
                        }
                    }

                    TextField("Year (optional)", text: $yearText)
                        .keyboardType(.numberPad)

                    Picker("Tag", selection: $tag) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag).tag(tag)
                        }
                    }

                    Toggle("Notify for this event", isOn: $notificationsEnabled)
                }

                if editingEvent != nil {
                    Section {
                        Button(role: .destructive) {
                            deleteEvent()
                        } label: {
                            Text("Delete Event")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(editingEvent == nil ? "Add Event" : "Edit Event")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: loadExisting)
        }
    }

    private func loadExisting() {
        guard let event = editingEvent else { return }
        name = event.nameText
        month = event.month
        day = event.day
        yearText = event.yearValue.map { String($0) } ?? ""
        tag = event.tagText
        notificationsEnabled = event.notificationsEnabledForEvent
    }

    private func save() {
        let event = editingEvent ?? LLCalendarEvent(context: context)

        if event.idValue == nil {
            event.idValue = UUID()
            event.createdAtValue = Date()
        }

        event.householdValue = household
        event.nameText = name.trimmingCharacters(in: .whitespacesAndNewlines)
        event.month = month
        event.day = day
        event.yearValue = Int16(yearText.trimmingCharacters(in: .whitespacesAndNewlines))
        event.tagText = tag
        event.notificationsEnabledForEvent = notificationsEnabled
        event.updatedAtValue = Date()

        do {
            try context.save()
            dismiss()
        } catch {
            context.rollback()
        }
    }

    private func deleteEvent() {
        guard let event = editingEvent else { return }
        context.delete(event)

        do {
            try context.save()
            dismiss()
        } catch {
            context.rollback()
        }
    }

    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        return formatter.monthSymbols[month - 1]
    }
}

extension LLCalendarEvent {
    var idValue: UUID? {
        get { value(forKey: "id") as? UUID }
        set { setValue(newValue, forKey: "id") }
    }

    var householdValue: Household? {
        get { value(forKey: "household") as? Household }
        set { setValue(newValue, forKey: "household") }
    }

    var nameText: String {
        get { (value(forKey: "name") as? String) ?? "Untitled" }
        set { setValue(newValue, forKey: "name") }
    }

    var tagText: String {
        get { (value(forKey: "tag") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Other" }
        set { setValue(newValue, forKey: "tag") }
    }

    var createdAtValue: Date {
        get { (value(forKey: "createdAt") as? Date) ?? .distantPast }
        set { setValue(newValue, forKey: "createdAt") }
    }

    var updatedAtValue: Date {
        get { (value(forKey: "updatedAt") as? Date) ?? .distantPast }
        set { setValue(newValue, forKey: "updatedAt") }
    }

    var yearValue: Int16? {
        get {
            if let number = value(forKey: "year") as? NSNumber {
                return number.int16Value
            }
            return value(forKey: "year") as? Int16
        }
        set {
            if let newValue {
                setValue(NSNumber(value: newValue), forKey: "year")
            } else {
                setValue(nil, forKey: "year")
            }
        }
    }

    var secondaryInfo: String {
        if let year = yearValue, year != 0 {
            return String(year)
        }
        return tagText
    }
}
