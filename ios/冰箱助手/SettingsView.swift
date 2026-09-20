import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inventory: InventoryStore
    @State private var showPermissionAlert = false
    @State private var requestingPermission = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(
                        "Expiring soon: \(inventory.thresholdDays) days",
                        value: $inventory.thresholdDays,
                        in: 1...14
                    )
                } footer: {
                    Text("Items with this many days remaining or less are shown in orange.")
                }

                Section("Recipes") {
                    Picker("Cuisine", selection: $inventory.cuisine) {
                        ForEach(Cuisine.allCases) { cuisine in
                            Text(cuisine.rawValue).tag(cuisine)
                        }
                    }
                }

                Section {
                    Toggle(
                        "Expiration reminders",
                        isOn: Binding(
                            get: { inventory.notificationsEnabled },
                            set: handleNotificationToggle
                        )
                    )
                    .disabled(requestingPermission)
                } footer: {
                    Text("When enabled, the app notifies you when food enters the expiring-soon range.")
                }

            }
            .scrollContentBackground(.hidden)
            .background(FridgeTheme.paper)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Notification Permission Needed", isPresented: $showPermissionAlert) {
                Button("Not Now", role: .cancel) {
                    inventory.setNotificationsEnabled(false)
                }
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            } message: {
                Text("Notifications are disabled. Allow FreshPeek to send notifications in Settings.")
            }
        }
    }

    private func handleNotificationToggle(_ wantsNotifications: Bool) {
        guard wantsNotifications else {
            inventory.setNotificationsEnabled(false)
            return
        }

        requestingPermission = true
        Task {
            let result = await NotificationManager.shared.requestPermission()
            requestingPermission = false
            switch result {
            case .granted:
                inventory.setNotificationsEnabled(true)
            case .denied:
                inventory.setNotificationsEnabled(false)
                showPermissionAlert = true
            }
        }
    }
}
