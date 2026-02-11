import SwiftUI
import CoreData
import UserNotifications
import UIKit

struct NotificationsSettingsView: View {
    let context: NSManagedObjectContext
    let household: Household?
    @Binding var showNotificationsDeniedAlert: Bool

    @AppStorage("ll_notify_enabled") private var notificationsEnabled = false
    @AppStorage("ll_notify_tag_birthday") private var notifyBirthday = true
    @AppStorage("ll_notify_tag_anniversary") private var notifyAnniversary = true
    @AppStorage("ll_notify_tag_family") private var notifyFamily = true
    @AppStorage("ll_notify_tag_milestone") private var notifyMilestone = true
    @AppStorage("ll_notify_tag_travel") private var notifyTravel = true
    @AppStorage("ll_notify_tag_medical") private var notifyMedical = true
    @AppStorage("ll_notify_tag_school") private var notifySchool = true
    @AppStorage("ll_notify_tag_work") private var notifyWork = true
    @AppStorage("ll_notify_tag_other") private var notifyOther = true

    @State private var permissionStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            eventNotificationsSection
            systemSection

            if notificationsEnabled {
                eventTypesSection

                Section {
                    Button("Resync Notifications") {
                        Task { @MainActor in
                            await NotificationScheduler.sync(context: context, household: household)
                        }
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .onAppear {
            Task {
                await refreshPermissionStatus()
            }
        }
        .onChange(of: notificationsEnabled) { newValue in
            Task { @MainActor in
                await handleNotificationsToggleChanged(newValue)
            }
        }
        .onChange(of: notifyBirthday) { _ in resyncNotificationsIfEnabled() }
        .onChange(of: notifyAnniversary) { _ in resyncNotificationsIfEnabled() }
        .onChange(of: notifyFamily) { _ in resyncNotificationsIfEnabled() }
        .onChange(of: notifyMilestone) { _ in resyncNotificationsIfEnabled() }
        .onChange(of: notifyTravel) { _ in resyncNotificationsIfEnabled() }
        .onChange(of: notifyMedical) { _ in resyncNotificationsIfEnabled() }
        .onChange(of: notifySchool) { _ in resyncNotificationsIfEnabled() }
        .onChange(of: notifyWork) { _ in resyncNotificationsIfEnabled() }
        .onChange(of: notifyOther) { _ in resyncNotificationsIfEnabled() }
    }

    private var eventNotificationsSection: some View {
        Section {
            Toggle("Event Notifications", isOn: $notificationsEnabled)
        } header: {
            Text("Event Notifications")
        } footer: {
            Text("Turn on reminders for your household events. These settings are saved on this device.")
        }
    }

    private var systemSection: some View {
        Section {
            HStack {
                Text("Permission")
                Spacer()
                Text(permissionStatusText)
                    .foregroundStyle(.secondary)
            }

            Button {
                openSystemNotificationSettings()
            } label: {
                Label("Open iPhone Settings", systemImage: "arrow.up.right.square")
            }
        } header: {
            Text("System")
        }
    }

    private var eventTypesSection: some View {
        Section {
            eventTypeToggle(icon: "gift.fill", title: "Birthdays", isOn: $notifyBirthday)
            eventTypeToggle(icon: "heart.fill", title: "Anniversaries", isOn: $notifyAnniversary)
            eventTypeToggle(icon: "person.3.fill", title: "Family", isOn: $notifyFamily)
            eventTypeToggle(icon: "flag.fill", title: "Milestones", isOn: $notifyMilestone)
            eventTypeToggle(icon: "airplane", title: "Travel", isOn: $notifyTravel)
            eventTypeToggle(icon: "cross.case.fill", title: "Medical", isOn: $notifyMedical)
            eventTypeToggle(icon: "graduationcap.fill", title: "School", isOn: $notifySchool)
            eventTypeToggle(icon: "briefcase.fill", title: "Work", isOn: $notifyWork)
            eventTypeToggle(icon: "tag.fill", title: "Other", isOn: $notifyOther)
        } header: {
            Text("Event Types")
        }
    }

    private func eventTypeToggle(icon: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Toggle(title, isOn: isOn)
        }
    }

    private var permissionStatusText: String {
        switch permissionStatus {
        case .authorized, .provisional, .ephemeral:
            return "Allowed"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not set"
        @unknown default:
            return "Unknown"
        }
    }

    @MainActor
    private func handleNotificationsToggleChanged(_ isEnabled: Bool) async {
        if isEnabled {
            let granted = await NotificationScheduler.requestAuthorizationIfNeeded()
            await refreshPermissionStatus()

            if !granted {
                notificationsEnabled = false
                showNotificationsDeniedAlert = true
                await NotificationScheduler.removeAllEventRequests()
                return
            }

            await NotificationScheduler.sync(context: context, household: household)
        } else {
            await NotificationScheduler.removeAllEventRequests()
            await refreshPermissionStatus()
        }
    }

    private func resyncNotificationsIfEnabled() {
        guard notificationsEnabled else { return }
        Task { @MainActor in
            await NotificationScheduler.sync(context: context, household: household)
        }
    }

    @MainActor
    private func refreshPermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettingsAsync()
        permissionStatus = settings.authorizationStatus
    }

    private func openSystemNotificationSettings() {
        guard let url = URL(string: notificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var notificationSettingsURLString: String {
        if #available(iOS 16.0, *) {
            return UIApplication.openNotificationSettingsURLString
        }
        return UIApplication.openSettingsURLString
    }
}

private extension UNUserNotificationCenter {
    func notificationSettingsAsync() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }
}
