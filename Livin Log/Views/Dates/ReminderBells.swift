//
//  ReminderBells.swift
//  Livin Log
//
//  The Calendar's reminder bells:
//  - RemindersToolbarBell: household-wide reminders on/off (NotificationScheduler.globalEnabledKey,
//    the same setting as Settings > Notifications > Event Notifications).
//  - EventReminderBell: one event's reminder (LLCalendarEvent.notificationsEnabledForEvent, a
//    per-device preference that never syncs). Turning one on also turns household-wide
//    reminders on, since nothing is scheduled while those are off.
//  Both ask for notification permission when it hasn't been asked yet, and offer Open Settings
//  when it was denied.

import SwiftUI
import CoreData

struct RemindersToolbarBell: View {
    let household: Household

    @Environment(\.managedObjectContext) private var context
    @AppStorage(NotificationScheduler.globalEnabledKey) private var remindersEnabled = false
    @State private var isWorking = false
    @State private var showDeniedAlert = false

    var body: some View {
#if DEBUG
        Menu {
            Button("Send Test Notification", systemImage: "bell.badge") {
                NotificationScheduler.sendTestNotification()
            }
        } label: {
            bellImage
        } primaryAction: {
            toggle()
        }
        .modifier(sharedModifiers)
#else
        Button {
            toggle()
        } label: {
            bellImage
        }
        .modifier(sharedModifiers)
#endif
    }

    private var bellImage: some View {
        Image(systemName: remindersEnabled ? "bell.fill" : "bell.slash")
    }

    private var sharedModifiers: some ViewModifier {
        ToolbarBellModifiers(
            remindersEnabled: remindersEnabled,
            isWorking: isWorking,
            showDeniedAlert: $showDeniedAlert
        )
    }

    private func toggle() {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            if remindersEnabled {
                await NotificationScheduler.disableGlobally()
            } else if await NotificationScheduler.enableGlobally() {
                await NotificationScheduler.sync(context: context, household: household)
            } else {
                showDeniedAlert = true
            }
        }
    }
}

private struct ToolbarBellModifiers: ViewModifier {
    let remindersEnabled: Bool
    let isWorking: Bool
    @Binding var showDeniedAlert: Bool

    func body(content: Content) -> some View {
        content
            .disabled(isWorking)
            .accessibilityLabel(remindersEnabled ? "Turn Off Event Reminders" : "Turn On Event Reminders")
            .notificationsDeniedAlert(isPresented: $showDeniedAlert)
    }
}

struct EventReminderBell: View {
    @ObservedObject var event: LLCalendarEvent
    let household: Household

    @AppStorage(NotificationScheduler.globalEnabledKey) private var remindersEnabled = false
    @State private var isWorking = false
    @State private var showDeniedAlert = false

    /// Whether this event will actually be reminded on this device.
    private var isOn: Bool {
        remindersEnabled && event.notificationsEnabledForEvent
    }

    var body: some View {
        Button {
            toggle()
        } label: {
            Image(systemName: isOn ? "bell.fill" : "bell.slash")
                .font(.subheadline)
                .foregroundStyle(isOn ? AppCategoryStyle.dates.accent : .secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(isWorking)
        .accessibilityLabel(isOn ? "Turn Off Reminder for \(event.nameText)" : "Turn On Reminder for \(event.nameText)")
        .notificationsDeniedAlert(isPresented: $showDeniedAlert)
    }

    private func toggle() {
        guard let context = event.managedObjectContext else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            let turnOn = !isOn
            if turnOn, !remindersEnabled {
                guard await NotificationScheduler.enableGlobally() else {
                    showDeniedAlert = true
                    return
                }
            }
            // Local-only field (not in LLCalendarEvent's syncedProperties), so this save
            // doesn't send anything to CloudKit.
            if event.notificationsEnabledForEvent != turnOn {
                event.notificationsEnabledForEvent = turnOn
                do {
                    try context.save()
                } catch {
                    context.rollback()
                    return
                }
            }
            await NotificationScheduler.sync(context: context, household: household)
        }
    }
}

extension View {
    /// "Notifications are off" alert with an Open Settings button, for when permission was denied.
    func notificationsDeniedAlert(isPresented: Binding<Bool>) -> some View {
        alert("Notifications Are Off", isPresented: isPresented) {
            Button("Open Settings") {
                if let url = NotificationScheduler.systemNotificationSettingsURL {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow notifications for Livin Log in iPhone Settings to get event reminders.")
        }
    }
}
