// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import UserNotifications

/// The slice of `UNUserNotificationCenter` the reminder scheduler uses. Tests give it a
/// fake, so no test ever posts a real notification.
@MainActor
protocol NotificationCenterClient: AnyObject {
    /// Asks for permission to show alerts and sounds; the system prompts only the first time.
    func requestAuthorization() async -> Bool
    /// Whether notifications may be shown right now. Never prompts.
    func isAuthorized() async -> Bool
    func pendingIdentifiers() async -> Set<String>
    func deliveredIdentifiers() async -> [String]
    /// The synchronous wrappers cold launch uses: no enumeration, no waiting.
    func removeDeliveredNow(_ ids: [String])
    func removePendingNow(_ ids: [String])
    /// Schedules `n` under `identifier` (the id comes from the ledger).
    func add(_ n: PlannedNotification, identifier: String) async throws
    func addTimer(identifier: String, title: String, at: Date) async throws
    func removePending(_ ids: [String])
    func removeDelivered(_ ids: [String])
    /// Registers the `reminder` category (`MacNotificationCategory.reminder`).
    func registerCategories()
}

/// The `reminder` category: two snooze actions, and `.customDismissAction` so a swipe-away reaches
/// the delegate.
enum MacNotificationCategory {
    static let snoozeHourTitle = "In 1 Hour"

    /// "At 9:00", with the time written the way the person's locale writes it ("At 9:00 AM", "At 09:00").
    static func snoozeNineTitle(locale: Locale = .current, calendar: Calendar = .current) -> String {
        "At " + nineOClock(locale: locale, calendar: calendar)
    }

    static func nineOClock(locale: Locale, calendar: Calendar) -> String {
        let nine = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 9, minute: 0)) ?? Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: nine)
    }

    static func reminder(locale: Locale = .current, calendar: Calendar = .current) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: NotificationLedger.categoryIdentifier,
            actions: [
                UNNotificationAction(identifier: NotificationLedger.snoozeHourAction, title: snoozeHourTitle, options: []),
                UNNotificationAction(
                    identifier: NotificationLedger.snoozeNineAction,
                    title: snoozeNineTitle(locale: locale, calendar: calendar), options: []),
            ],
            intentIdentifiers: [], options: [.customDismissAction])
    }
}

/// The client of a process that must not talk to the system: it shows nothing and reports no
/// permission. The default of `AppEnvironment`, so only the app's own launch turns reminders on.
@MainActor
final class NullNotificationCenter: NotificationCenterClient {
    func requestAuthorization() async -> Bool { false }
    func isAuthorized() async -> Bool { false }
    func pendingIdentifiers() async -> Set<String> { [] }
    func deliveredIdentifiers() async -> [String] { [] }
    func removeDeliveredNow(_ ids: [String]) {}
    func removePendingNow(_ ids: [String]) {}
    func add(_ n: PlannedNotification, identifier: String) async throws {}
    func addTimer(identifier: String, title: String, at: Date) async throws {}
    func removePending(_ ids: [String]) {}
    func removeDelivered(_ ids: [String]) {}
    func registerCategories() {}
}

/// The real thing. Notification content never carries a note id or any text beyond the planned
/// title and body (the plan already redacts for App Lock and locked notes).
@MainActor
final class LiveNotificationCenter: NotificationCenterClient {
    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isAuthorized() async -> Bool {
        let status: UNAuthorizationStatus = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { continuation.resume(returning: $0.authorizationStatus) }
        }
        return status == .authorized || status == .provisional
    }

    func pendingIdentifiers() async -> Set<String> {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests {
                continuation.resume(returning: Set($0.map(\.identifier)))
            }
        }
    }

    func deliveredIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications {
                continuation.resume(returning: $0.map(\.request.identifier))
            }
        }
    }

    func removeDeliveredNow(_ ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }
    func removePendingNow(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func removePending(_ ids: [String]) { removePendingNow(ids) }
    func removeDelivered(_ ids: [String]) { removeDeliveredNow(ids) }

    /// What the system shows for a planned reminder: the note title as the title, the line as the
    /// body, in separate fields.
    static func content(for n: PlannedNotification) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = n.title
        if let body = n.body { content.body = body }
        content.sound = .default
        content.categoryIdentifier = NotificationLedger.categoryIdentifier
        return content
    }

    func add(_ n: PlannedNotification, identifier: String) async throws {
        try await center.add(UNNotificationRequest(identifier: identifier, content: Self.content(for: n), trigger: Self.trigger(at: n.fireAt)))
    }

    func addTimer(identifier: String, title: String, at: Date) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: Self.trigger(at: at)))
    }

    func registerCategories() {
        center.setNotificationCategories([MacNotificationCategory.reminder()])
    }

    /// One-shot calendar trigger on the exact local date and time.
    private static func trigger(at date: Date) -> UNCalendarNotificationTrigger {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
        return UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
    }
}
