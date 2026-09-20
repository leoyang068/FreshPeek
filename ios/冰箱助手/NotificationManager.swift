import Foundation
import UserNotifications

actor NotificationManager {
    static let shared = NotificationManager()

    enum PermissionResult {
        case granted
        case denied
    }

    func requestPermission() async -> PermissionResult {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                return granted ? .granted : .denied
            } catch {
                return .denied
            }
        @unknown default:
            return .denied
        }
    }

    func scheduleExpiryReminders(for items: [FoodItem], thresholdDays: Int) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix("expiry-") }
        center.removePendingNotificationRequests(withIdentifiers: ids)

        let calendar = Calendar.current
        let now = Date()

        for item in items.prefix(50) {
            let reminderDate = calendar.date(
                byAdding: .day,
                value: -thresholdDays,
                to: item.expiryDate
            ) ?? item.expiryDate

            var fireDate = calendar.date(
                bySettingHour: 9,
                minute: 0,
                second: 0,
                of: reminderDate
            ) ?? reminderDate

            if fireDate <= now {
                fireDate = now.addingTimeInterval(10)
            }

            let content = UNMutableNotificationContent()
            content.title = "Food in your fridge is expiring soon"
            content.body = "\(item.name): \(item.statusText())"
            content.sound = .default

            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: "expiry-\(item.id.uuidString)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    func clearExpiryReminders() async {
        let center = UNUserNotificationCenter.current()
        let requests = await center.pendingNotificationRequests()
        let ids = requests.map(\.identifier).filter { $0.hasPrefix("expiry-") }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
