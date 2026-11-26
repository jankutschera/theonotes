// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB
import Testing
import UserNotifications
@testable import TheoNotes

/// A notification center that keeps its state in memory and records every call. Nothing here can
/// show a real notification.
@MainActor
final class FakeNotificationCenter: NotificationCenterClient {
    struct Request: Equatable {
        let identifier: String
        let title: String
        let body: String?
        let fireAt: Date
    }

    private(set) var pending: [String: Request] = [:]
    var delivered: [String] = []
    var authorized = true
    private(set) var authorizationRequests = 0
    private(set) var categoriesRegistered = 0
    private(set) var enumerations = 0
    /// Cold launch must not enumerate: with this set, `deliveredIdentifiers` traps.
    var forbidEnumeration = false

    private(set) var removedDeliveredNow: [String] = []
    private(set) var removedPendingNow: [String] = []
    private(set) var removedDelivered: [String] = []
    private(set) var removedPending: [String] = []
    private(set) var addAttempts: [String] = []
    private(set) var timers: [String: String] = [:]
    /// The next adds throw without scheduling anything.
    var failAdds = 0
    /// The next adds schedule the request and then throw (the call failed after the system took it).
    var failAfterStoring = 0
    /// An add takes a few turns of the main actor to complete, as the real center's does.
    var slowAdds = false
    /// What a test reads at the moment an add runs (the ledger rows).
    var onAdd: ((String) -> Void)?

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return authorized
    }

    func isAuthorized() async -> Bool { authorized }

    func pendingIdentifiers() async -> Set<String> {
        precondition(!forbidEnumeration, "enumerated the notification center")
        enumerations += 1
        return Set(pending.keys)
    }

    func deliveredIdentifiers() async -> [String] {
        precondition(!forbidEnumeration, "enumerated the notification center")
        return delivered
    }

    func removeDeliveredNow(_ ids: [String]) {
        removedDeliveredNow += ids
        delivered.removeAll { ids.contains($0) }
    }

    func removePendingNow(_ ids: [String]) {
        removedPendingNow += ids
        ids.forEach { pending[$0] = nil }
    }

    func removeDelivered(_ ids: [String]) {
        removedDelivered += ids
        delivered.removeAll { ids.contains($0) }
    }

    func removePending(_ ids: [String]) {
        removedPending += ids
        ids.forEach { pending[$0] = nil }
    }

    func add(_ n: PlannedNotification, identifier: String) async throws {
        addAttempts.append(identifier)
        onAdd?(identifier)
        if slowAdds { for _ in 0..<20 { await Task.yield() } }
        if failAdds > 0 {
            failAdds -= 1
            throw CocoaError(.fileWriteUnknown)
        }
        pending[identifier] = Request(identifier: identifier, title: n.title, body: n.body, fireAt: n.fireAt)
        if failAfterStoring > 0 {
            failAfterStoring -= 1
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func addTimer(identifier: String, title: String, at: Date) async throws {
        onAdd?(identifier)
        timers[identifier] = title
        pending[identifier] = Request(identifier: identifier, title: title, body: nil, fireAt: at)
    }

    func registerCategories() { categoriesRegistered += 1 }

    /// The system delivered a pending request while the app was not looking.
    func deliver(_ identifier: String) {
        pending[identifier] = nil
        delivered.append(identifier)
    }

    var pendingRequests: [Request] { pending.values.sorted { $0.fireAt < $1.fireAt } }
}

final class ReminderClock: @unchecked Sendable {
    var now = Date()
}

/// A temporary library with a real `AppEnvironment` whose notification center is the fake.
@MainActor
final class ReminderEnv {
    let root: URL
    let center: FakeNotificationCenter
    let authenticator = FakeAppAuthenticator()
    let clock = ReminderClock()
    let environment: AppEnvironment
    let ownsRoot: Bool
    private nonisolated(unsafe) let pool: any DatabaseWriter

    /// `center` and `root` let a test relaunch the same library with a fresh center.
    init(root: URL? = nil, center: FakeNotificationCenter = FakeNotificationCenter(), clock: ReminderClock? = nil,
         forbidEnumerationDuringInit: Bool = false) throws {
        ownsRoot = root == nil
        self.root = root ?? URL(fileURLWithPath: "/tmp/theo-remind-\(UUID().uuidString.prefix(8))", isDirectory: true)
        self.center = center
        if let clock { self.clock.now = clock.now }
        center.forbidEnumeration = forbidEnumerationDuringInit
        let box = self.clock
        environment = try AppEnvironment(
            paths: AppPaths(root: self.root), vaultCache: FakeVaultKeyCache(), vaultLifecycle: nil,
            appAuthenticator: authenticator, appLockLifecycle: nil, appIdleSeconds: { 0 },
            notificationCenter: center, reminderNow: { box.now })
        pool = environment.database.pool
        center.forbidEnumeration = false
    }

    deinit {
        try? pool.close()
        if ownsRoot { try? FileManager.default.removeItem(at: root) }
    }

    var store: NoteStore { environment.store }
    var reminders: MacNotificationScheduler { environment.reminders }
    var ledger: NotificationLedger { NotificationLedger(store: store) }

    /// Closes this library's database so the same folder can be opened again (a relaunch).
    func shutDown() { try? environment.database.pool.close() }

    func relaunch(center: FakeNotificationCenter = FakeNotificationCenter(), appLockEnabled: Bool? = nil,
                  forbidEnumerationDuringInit: Bool = false) throws -> ReminderEnv {
        if let appLockEnabled { TheoNotesCore.Settings(db: environment.database).appLockEnabled = appLockEnabled }
        shutDown()
        return try ReminderEnv(root: root, center: center, clock: clock, forbidEnumerationDuringInit: forbidEnumerationDuringInit)
    }

    /// A note "Title" with the line `line` and a line reminder `hours` ahead.
    @discardableResult
    func lineReminder(text: String = "Title\nbuy milk\nsecond", line: Int = 2, hours: Double = 1) throws -> (note: Note, ping: Ping) {
        let note = try store.create(text: text)
        let anchor = try #require(LineAnchor.at(line: line, in: text))
        let ping = try store.setPing(noteId: note.id, anchor: anchor, fireAt: clock.now.addingTimeInterval(hours * 3600), now: clock.now)
        return (note, ping)
    }

    func lockNote(_ id: String) async throws {
        try await environment.vault.createPassword("correct horse")
        try environment.vault.requireAccess().lock(noteId: id)
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

@MainActor
@Suite struct MacNotificationSchedulerTests {
    // MARK: plan to center

    @Test func reconcileAddsPlannedAndRemovesStale() async throws {
        let env = try ReminderEnv()
        let (note, ping) = try env.lineReminder()
        let second = try env.store.create(text: "Other")
        try env.store.setPing(noteId: second.id, anchor: nil, fireAt: env.clock.now.addingTimeInterval(7200))

        await env.reminders.reconcile()
        let requests = env.center.pendingRequests
        #expect(requests.count == 2)
        #expect(requests[0].title == "Title" && requests[0].body == "buy milk")
        #expect(requests[1].title == "Other" && requests[1].body == nil)
        let firstId = try #require(requests.first?.identifier)
        #expect(firstId.hasPrefix("reminder:\(ping.id):"))
        #expect(!firstId.contains("buy milk") && !firstId.contains(note.id))

        await env.reminders.reconcile()
        #expect(env.center.addAttempts.count == 2, "an unchanged plan adds nothing again")

        try env.store.handlePing(id: ping.id)
        await env.reminders.reconcile()
        #expect(env.center.pending.keys.contains(firstId) == false)
        #expect(env.center.pendingRequests.map(\.title) == ["Other"])
        #expect(try env.ledger.entries().count == 1, "the removed row is forgotten once it is gone")
    }

    @Test func noMoreThanSixtyFourAreScheduled() async throws {
        let env = try ReminderEnv()
        for index in 0..<70 {
            let note = try env.store.create(text: "Note \(index)")
            try env.store.setPing(noteId: note.id, anchor: nil, fireAt: env.clock.now.addingTimeInterval(Double(3600 + index)))
        }
        await env.reminders.reconcile()
        #expect(env.center.pending.count == MacNotificationScheduler.scheduleCap)
        #expect(MacNotificationScheduler.scheduleCap == 64)
        #expect(env.center.pendingRequests.map(\.title).last == "Note 63", "the earliest 64 are the ones scheduled")
    }

    @Test func concurrentReconcilesNeverAddTwice() async throws {
        let env = try ReminderEnv()
        try env.lineReminder()
        env.center.slowAdds = true
        let scheduler = env.reminders
        // The second call arrives while the first pass is inside its add.
        let first = Task { @MainActor in await scheduler.reconcile() }
        for _ in 0..<3 { await Task.yield() }
        let second = Task { @MainActor in await scheduler.reconcile() }
        await first.value
        await second.value
        #expect(env.center.addAttempts.count == 1)
        #expect(env.center.pending.count == 1)
    }

    @Test func typingAloneDoesNotEnumerateTheCenter() async throws {
        let env = try ReminderEnv()
        try env.lineReminder()
        await env.reminders.reconcile()
        let before = env.center.enumerations
        await env.reminders.reconcile(sweep: false)
        #expect(env.center.enumerations == before)
        await env.reminders.reconcile()
        #expect(env.center.enumerations > before)
    }

    // MARK: App Lock and locked notes

    @Test func appLockEnabledReplansWithGenericTextAndRemovesDeliveredText() async throws {
        let first = try ReminderEnv()
        try first.lineReminder()
        await first.reminders.reconcile()
        let oldId = try #require(first.center.pending.keys.first)
        #expect(first.center.pendingRequests.first?.body == "buy milk")
        // The text was delivered, then the library is opened with App Lock on.
        let center = FakeNotificationCenter()
        center.delivered = [oldId]
        let env = try first.relaunch(center: center, appLockEnabled: true)

        #expect(center.removedDeliveredNow == [oldId], "launch scrub, before any window")
        await env.reminders.reconcile()
        #expect(center.delivered.isEmpty)
        #expect(center.pendingRequests.map { [$0.title, $0.body ?? ""] } == [["Theo Notes", "Reminder"]])
        let newId = center.pendingRequests.first?.identifier ?? ""
        #expect(newId != oldId && newId.hasPrefix("reminder:"))
    }

    @Test func noteLockRemovesItsDeliveredReminders() async throws {
        let env = try ReminderEnv()
        let (note, _) = try env.lineReminder()
        await env.reminders.reconcile()
        let oldId = try #require(env.center.pending.keys.first)
        env.center.deliver(oldId)

        try await env.lockNote(note.id)
        await env.reminders.reconcile()

        #expect(env.center.delivered.isEmpty)
        #expect(env.center.removedDelivered.contains(oldId))
        let request = try #require(env.center.pendingRequests.first)
        #expect(env.center.pendingRequests.count == 1)
        #expect(request.title == "Title" && request.body == nil, "a locked note's reminder is title only")
    }

    @Test func vaultLockThroughTheEnvironmentScrubsDeliveredReminders() async throws {
        let env = try ReminderEnv()
        let (note, _) = try env.lineReminder()
        await env.reminders.reconcile()
        let oldId = try #require(env.center.pending.keys.first)
        env.center.deliver(oldId)

        // The password is set first and the reconcile its unlock asks for is allowed to finish, so
        // only the relock below can bring about the next one.
        try await env.environment.vault.createPassword("correct horse")
        try await Task.sleep(for: .milliseconds(100))
        await env.reminders.reconcile()
        try env.environment.vault.requireAccess().lock(noteId: note.id)
        env.environment.vault.relock()
        await env.waitUntil { env.center.delivered.isEmpty && env.center.pending.count == 1 && env.center.pendingRequests.first?.body == nil }

        #expect(env.center.delivered.isEmpty)
        #expect(env.center.removedDelivered.contains(oldId))
        #expect(env.center.pendingRequests.map(\.title) == ["Title"])
        #expect(env.center.pendingRequests.first?.body == nil)
    }

    @Test func initWithAppLockEnabledScrubsDeliveredBeforeTheFirstWindow() async throws {
        let first = try ReminderEnv()
        try first.lineReminder()
        await first.reminders.reconcile()
        let id = try #require(first.center.pending.keys.first)
        let center = FakeNotificationCenter()
        center.delivered = [id] // delivered, not pending, in the new process's center
        let env = try first.relaunch(center: center, appLockEnabled: true)
        #expect(env.environment.appLock.isEnabled)
        #expect(center.removedDeliveredNow == [id])
        #expect(center.removedPendingNow == [id])
    }

    @Test func coldLaunchScrubsLedgerIdsSynchronouslyWithoutEnumerating() async throws {
        let first = try ReminderEnv()
        let (locked, _) = try first.lineReminder(text: "Locked\nsecret line")
        let (gone, _) = try first.lineReminder(text: "Gone\nline two")
        let (open, _) = try first.lineReminder(text: "Open\nline two")
        await first.reminders.reconcile()
        try await first.lockNote(locked.id)
        try first.store.trash([gone.id])
        try first.store.deletePermanently([gone.id])
        await first.reminders.reconcile()
        // Rows a crash left behind, with text-bearing notifications that were never retired.
        for (index, noteId) in [locked.id, gone.id].enumerated() {
            try first.ledger.record(
                LedgerEntry(identifier: "reminder:left\(index):aaaaaaaa-0000-0000-0000-00000000000\(index)", kind: .reminder,
                            pingId: "left\(index)", noteId: noteId, contentHash: "abcd1234"), now: first.clock.now)
        }
        let entries = try first.ledger.entries()
        let expected = Set(entries.filter { [locked.id, gone.id].contains($0.noteId ?? "") }.map(\.identifier))
        let openIds = Set(entries.filter { $0.noteId == open.id }.map(\.identifier))
        #expect(expected.count >= 2 && !openIds.isEmpty)

        let center = FakeNotificationCenter()
        let env = try first.relaunch(center: center, forbidEnumerationDuringInit: true)

        #expect(Set(center.removedDeliveredNow) == expected)
        #expect(Set(center.removedPendingNow) == expected)
        #expect(openIds.isDisjoint(with: Set(center.removedDeliveredNow)))
        #expect(center.enumerations == 0)
        _ = env
    }

    @Test func asyncSweepRemovesUnknownReminderIdsAndReadsBack() async throws {
        let env = try ReminderEnv()
        try env.lineReminder()
        env.center.delivered = ["reminder:ghost:11111111-1111-1111-1111-111111111111"]
        env.center.deliver("reminder:ghost:11111111-1111-1111-1111-111111111111")
        // A row for a notification that is not in the center any more.
        try env.ledger.record(LedgerEntry(identifier: "reminder:lost:u", kind: .reminder, pingId: "lost", noteId: nil, contentHash: "abcd1234"), now: env.clock.now)

        await env.reminders.reconcile()

        #expect(env.center.delivered.isEmpty)
        #expect(env.center.removedDelivered.contains("reminder:ghost:11111111-1111-1111-1111-111111111111"))
        #expect(env.center.enumerations >= 2, "enumerated, removed, enumerated again")
        let ids = try env.ledger.entries().map(\.identifier)
        #expect(!ids.contains("reminder:lost:u"), "a row whose notification is gone is forgotten")
        #expect(ids.count == 1)
    }

    @Test func crashBetweenRecordAndAddLeavesAKnownId() async throws {
        let first = try ReminderEnv()
        let (note, _) = try first.lineReminder()
        first.center.failAfterStoring = 1
        var rowExistedAtAdd = false
        first.center.onAdd = { id in rowExistedAtAdd = ((try? first.ledger.entries()) ?? []).contains { $0.identifier == id } }
        await first.reminders.reconcile()
        #expect(rowExistedAtAdd, "the row is recorded before the add")
        let id = try #require(first.center.pending.keys.first)
        #expect(try first.ledger.entries().map(\.identifier) == [id], "the id stays known although add threw")

        // The note is trashed for good; the next cold launch removes the id it knows.
        try first.store.trash([note.id])
        try first.store.deletePermanently([note.id])
        let center = FakeNotificationCenter()
        let env = try first.relaunch(center: center)
        #expect(center.removedPendingNow == [id])
        #expect(center.removedDeliveredNow == [id])
        _ = env
    }

    @Test func aFailedAddIsTriedAgainOnce() async throws {
        let env = try ReminderEnv()
        try env.lineReminder()
        env.center.failAdds = 1
        await env.reminders.reconcile()
        #expect(env.center.addAttempts.count == 2)
        #expect(env.center.pending.count == 1)
        env.center.failAdds = 100
        let other = try env.store.create(text: "Other")
        try env.store.setPing(noteId: other.id, anchor: nil, fireAt: env.clock.now.addingTimeInterval(9000))
        try await Task.sleep(for: .milliseconds(150)) // reconciles the change itself asked for finish first
        let before = env.center.addAttempts.count
        await env.reminders.reconcile()
        #expect(env.center.addAttempts.count - before <= 2, "a failing add is tried twice in a call, not forever")
    }

    // MARK: delegate

    @Test func dismissActionDeletesTheRow() async throws {
        let env = try ReminderEnv()
        let (_, ping) = try env.lineReminder()
        await env.reminders.reconcile()
        let id = try #require(env.center.pending.keys.first)
        await env.reminders.handle(actionIdentifier: UNNotificationDismissActionIdentifier, requestIdentifier: id)
        #expect(try env.store.ping(id: ping.id) == nil)
        #expect(env.center.pending.isEmpty)
    }

    @Test func categoryRegistersCustomDismissAction() throws {
        let env = try ReminderEnv()
        #expect(env.center.categoriesRegistered >= 1)
        let category = MacNotificationCategory.reminder()
        #expect(category.identifier == "reminder")
        #expect(category.options.contains(.customDismissAction))
        #expect(category.actions.map(\.identifier) == ["reminder.snooze.hour", "reminder.snooze.nine"])
        // The brief's copy: "In 1 Hour" and "At 9:00" in the locale's time format.
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let nine = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 9)))
        #expect(category.actions.map(\.title) == ["In 1 Hour", "At " + formatter.string(from: nine)])
    }

    @Test func tapOpensTheNoteAtTheLineAndDeletesTheRow() async throws {
        let env = try ReminderEnv()
        let text = "Title\nfirst\nsecond line"
        let (note, ping) = try env.lineReminder(text: text, line: 3)
        var opened: [(String, Int?)] = []
        env.reminders.openNote = { id, caret in opened.append((id, caret)); return true }
        await env.reminders.reconcile()
        let id = try #require(env.center.pending.keys.first)

        await env.reminders.handle(actionIdentifier: UNNotificationDefaultActionIdentifier, requestIdentifier: id)

        #expect(opened.count == 1 && opened[0].0 == note.id)
        #expect(opened[0].1 == LineAnchor.utf16Offset(ofLine: 3, in: text))
        #expect(try env.store.ping(id: ping.id) == nil)
    }

    @Test func aTapThatCouldNotOpenTheNoteKeepsTheReminder() async throws {
        let env = try ReminderEnv()
        let (_, ping) = try env.lineReminder()
        env.reminders.openNote = { _, _ in false }
        await env.reminders.reconcile()
        let id = try #require(env.center.pending.keys.first)
        await env.reminders.handle(actionIdentifier: UNNotificationDefaultActionIdentifier, requestIdentifier: id)
        #expect(try env.store.ping(id: ping.id) != nil)
    }

    @Test func snoozeReplacesTheRowOnce() async throws {
        let env = try ReminderEnv()
        let (_, ping) = try env.lineReminder()
        await env.reminders.reconcile()
        let oldId = try #require(env.center.pending.keys.first)

        await env.reminders.handle(actionIdentifier: NotificationLedger.snoozeHourAction, requestIdentifier: oldId)
        await env.reminders.handle(actionIdentifier: NotificationLedger.snoozeHourAction, requestIdentifier: oldId)

        let rows = try env.store.pings()
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.id != ping.id)
        #expect(row.anchor == ping.anchor)
        #expect(abs(row.fireAt.timeIntervalSince(env.clock.now.addingTimeInterval(3600))) < 1)
        #expect(env.center.pending[oldId] == nil)
        #expect(env.center.pendingRequests.count == 1)
        #expect(env.center.pendingRequests.first?.identifier.hasPrefix("reminder:\(row.id):") == true)
    }

    @Test func snoozeToNineMovesToTheNextNine() async throws {
        let env = try ReminderEnv()
        try env.lineReminder()
        await env.reminders.reconcile()
        let oldId = try #require(env.center.pending.keys.first)
        await env.reminders.handle(actionIdentifier: NotificationLedger.snoozeNineAction, requestIdentifier: oldId)
        let row = try #require(try env.store.pings().first)
        #expect(row.fireAt == PingTime.defaultFireDate(now: env.clock.now, calendar: .current))
    }

    @Test func aStaleOrUnknownNotificationChangesNothing() async throws {
        let env = try ReminderEnv()
        let (_, ping) = try env.lineReminder()
        await env.reminders.handle(actionIdentifier: UNNotificationDismissActionIdentifier, requestIdentifier: "timer:abc")
        await env.reminders.handle(actionIdentifier: UNNotificationDismissActionIdentifier, requestIdentifier: "something-else")
        #expect(try env.store.ping(id: ping.id) != nil)
    }

    @Test func presentationOnlyForKnownIdsAndItMarksTheReminderFired() async throws {
        let env = try ReminderEnv()
        let (_, ping) = try env.lineReminder()
        await env.reminders.reconcile()
        let id = try #require(env.center.pending.keys.first)
        #expect(!env.reminders.willPresent(requestIdentifier: "reminder:ghost:u"))
        #expect(try env.store.ping(id: ping.id)?.firedAt == nil)
        #expect(env.reminders.willPresent(requestIdentifier: id))
        #expect(try env.store.ping(id: ping.id)?.firedAt != nil)
    }

    // MARK: presentation

    @Test func aReminderIsNotShownOnceItsNoteIsLocked() async throws {
        let env = try ReminderEnv()
        let (note, ping) = try env.lineReminder()
        await env.reminders.reconcile()
        let id = try #require(env.center.pending.keys.first)
        try await env.environment.vault.createPassword("correct horse")
        try await Task.sleep(for: .milliseconds(100))

        // No turn of the main actor between the lock and the delivery: no reconcile ran in between.
        try env.environment.vault.requireAccess().lock(noteId: note.id)
        let shown = env.reminders.willPresent(requestIdentifier: id)

        #expect(!shown, "the notification was written with the note's text before it was locked")
        #expect(env.center.removedDeliveredNow.contains(id) && env.center.removedPendingNow.contains(id))
        #expect(try env.store.ping(id: ping.id)?.firedAt != nil, "it stays a due reminder for Next Up")
    }

    @Test func aReminderScheduledBeforeAppLockWasEnabledIsNotShownBeforeTheNextReconcile() async throws {
        let first = try ReminderEnv()
        let (_, ping) = try first.lineReminder()
        await first.reminders.reconcile()
        let oldId = try #require(first.center.pending.keys.first)
        // App Lock is on at the next launch; the old request is still in the ledger, no reconcile yet.
        let center = FakeNotificationCenter()
        let env = try first.relaunch(center: center, appLockEnabled: true)

        #expect(!env.reminders.willPresent(requestIdentifier: oldId))
        #expect(try env.store.ping(id: ping.id)?.firedAt != nil)

        // A reminder set while App Lock is on is scheduled in the generic form, and that may be shown.
        let other = try env.store.create(text: "Other\nsecret line")
        try env.store.setPing(noteId: other.id, anchor: LineAnchor.at(line: 2, in: "Other\nsecret line"), fireAt: env.clock.now.addingTimeInterval(7200))
        await env.reminders.reconcile()
        let request = try #require(center.pendingRequests.first)
        #expect(request.title == "Theo Notes" && request.body == "Reminder")
        #expect(env.reminders.willPresent(requestIdentifier: request.identifier))
    }

    @Test func aDeletedNotesReminderIsNotShown() async throws {
        let env = try ReminderEnv()
        let (note, _) = try env.lineReminder()
        await env.reminders.reconcile()
        let id = try #require(env.center.pending.keys.first)
        try env.store.trash([note.id])
        try env.store.deletePermanently([note.id])
        #expect(!env.reminders.willPresent(requestIdentifier: id))
        #expect(env.center.removedDeliveredNow.contains(id))
    }

    @Test func aHandledOrSnoozedReminderIsNotShownAgain() async throws {
        let env = try ReminderEnv()
        let (_, ping) = try env.lineReminder()
        await env.reminders.reconcile()
        let id = try #require(env.center.pending.keys.first)
        try env.store.handlePing(id: ping.id)
        #expect(!env.reminders.willPresent(requestIdentifier: id))
    }

    // MARK: permission, launch, activation, timers

    @Test func deniedAuthorizationKeepsRowsAndSchedulesNothing() async throws {
        let env = try ReminderEnv()
        env.center.authorized = false
        let note = try env.store.create(text: "Title\nline")
        let outcome = try await env.reminders.setReminder(noteId: note.id, anchor: nil, fireAt: env.clock.now.addingTimeInterval(3600))
        #expect(outcome == .notificationsOff)
        #expect(env.center.authorizationRequests == 1)
        #expect(try env.store.pings().count == 1)
        #expect(env.center.addAttempts.isEmpty && env.center.pending.isEmpty)
        #expect(try env.ledger.entries().isEmpty)
        // Allowed later: the kept reminder is scheduled by the next reconcile.
        env.center.authorized = true
        await env.reminders.reconcile()
        #expect(env.center.pending.count == 1)
    }

    @Test func settingAReminderSchedulesIt() async throws {
        let env = try ReminderEnv()
        let note = try env.store.create(text: "Title\nline")
        let outcome = try await env.reminders.setReminder(noteId: note.id, anchor: nil, fireAt: env.clock.now.addingTimeInterval(3600))
        #expect(outcome == .scheduled)
        #expect(env.center.pending.count == 1)
    }

    @Test func launchMarksPastRemindersFired() async throws {
        let env = try ReminderEnv()
        let note = try env.store.create(text: "Title\nline")
        let later = try env.store.create(text: "Later")
        let past = try env.store.setPing(noteId: note.id, anchor: nil, fireAt: env.clock.now.addingTimeInterval(-600))
        let future = try env.store.setPing(noteId: later.id, anchor: nil, fireAt: env.clock.now.addingTimeInterval(3600))

        await env.reminders.catchUp()

        #expect(try env.store.ping(id: past.id)?.firedAt != nil, "seen past due: a due card candidate")
        #expect(try env.store.ping(id: future.id)?.firedAt == nil)
        #expect(env.center.pendingRequests.map(\.title) == ["Later"])
    }

    @Test func activationMarksRemindersDeliveredInTheBackgroundFired() async throws {
        let env = try ReminderEnv()
        let (_, ping) = try env.lineReminder()
        await env.reminders.reconcile()
        let id = try #require(env.center.pending.keys.first)
        env.center.deliver(id) // the Mac showed it while the app was in the background
        env.clock.now = env.clock.now.addingTimeInterval(2 * 3600)

        await env.reminders.catchUp()

        #expect(try env.store.ping(id: ping.id)?.firedAt != nil)
        #expect(env.center.delivered == [id], "the banner stays until the person deals with it")
        #expect(!env.center.removedDelivered.contains(id))
        // Dealing with it retires the row.
        await env.reminders.handle(actionIdentifier: UNNotificationDismissActionIdentifier, requestIdentifier: id)
        env.center.delivered = []
        await env.reminders.reconcile()
        #expect(try env.ledger.entries().isEmpty)
    }

    @Test func aDuePendingRequestIsNotTreatedAsDelivered() async throws {
        let env = try ReminderEnv()
        let (note, _) = try env.lineReminder(text: "Title\nbuy milk\nsecond")
        await env.reminders.reconcile()
        let id = try #require(env.center.pending.keys.first)
        env.clock.now = env.clock.now.addingTimeInterval(2 * 3600) // due, but the Mac has delivered nothing
        _ = try env.store.updateText(id: note.id, text: "Renamed\nbuy milk\nsecond", expectedRevision: note.revision)

        await env.reminders.reconcile()

        #expect(env.center.pending[id] == nil, "a request whose content changed is not kept just because it is due")
        #expect(env.center.removedPending.contains(id))
        #expect(env.center.delivered.isEmpty)
    }

    @Test func aDuePendingRequestThatIsUnchangedStaysUntilTheMacDeliversIt() async throws {
        let env = try ReminderEnv()
        try env.lineReminder()
        await env.reminders.reconcile()
        let id = try #require(env.center.pending.keys.first)
        env.clock.now = env.clock.now.addingTimeInterval(2 * 3600)
        await env.reminders.reconcile()
        #expect(env.center.pending[id] != nil)
        #expect(!env.center.removedPending.contains(id) && !env.center.removedDelivered.contains(id))
    }

    @Test func aDeliveredReminderGoesWhenItsNoteIsTrashed() async throws {
        let env = try ReminderEnv()
        let (note, _) = try env.lineReminder()
        await env.reminders.reconcile()
        let id = try #require(env.center.pending.keys.first)
        env.center.deliver(id)
        env.clock.now = env.clock.now.addingTimeInterval(2 * 3600)
        await env.reminders.catchUp()
        #expect(env.center.delivered == [id])

        try env.store.trash([note.id])
        await env.reminders.reconcile()
        #expect(env.center.delivered.isEmpty)
    }

    @Test func theSystemNotificationCarriesTheTitleAndTheLineInSeparateFields() {
        let planned = PlannedNotification(
            pingId: "p", noteId: "n", title: "Plan", body: "one", fireAt: Date(), line: 2, contentHash: "abcd1234")
        let content = LiveNotificationCenter.content(for: planned)
        #expect(content.title == "Plan")
        #expect(content.body == "one")
        #expect(content.categoryIdentifier == NotificationLedger.categoryIdentifier)
        let titleOnly = LiveNotificationCenter.content(for: PlannedNotification(
            pingId: "p", noteId: "n", title: "Plan", body: nil, fireAt: Date(), line: nil, contentHash: "abcd1234"))
        #expect(titleOnly.title == "Plan" && titleOnly.body.isEmpty)
    }

    /// (K5): the tap launches the app; macOS has already taken the banner out of the center, so
    /// launch catch-up sees nothing delivered and forgets the ledger row before the tap arrives.
    @Test func aTapThatLaunchedTheAppStillHandlesTheReminder() async throws {
        let env = try ReminderEnv()
        let (note, ping) = try env.lineReminder(text: "Title\nbuy milk", line: 2)
        await env.reminders.reconcile()
        let id = try #require(env.center.pending.keys.first)
        env.center.deliver(id)
        env.clock.now = env.clock.now.addingTimeInterval(2 * 3600)
        env.center.delivered = [] // the tap took the banner away; the app was not running

        let relaunched = try env.relaunch(center: env.center)
        var opened: [String] = []
        relaunched.reminders.openNote = { noteId, _ in opened.append(noteId); return true }
        await relaunched.reminders.catchUp()
        await relaunched.reminders.handle(actionIdentifier: UNNotificationDefaultActionIdentifier, requestIdentifier: id)

        #expect(opened == [note.id])
        #expect(try relaunched.store.ping(id: ping.id) == nil, "a handled reminder is gone, so Next Up cannot offer it")
    }

    @Test func aTimerIsRecordedBeforeItIsAddedAndNeverRemovedByReconcile() async throws {
        let env = try ReminderEnv()
        var recorded = false
        env.center.onAdd = { id in recorded = ((try? env.ledger.entries()) ?? []).contains { $0.identifier == id && $0.kind == .timer } }
        let id = try await env.reminders.scheduleTimer(title: "Break", at: env.clock.now.addingTimeInterval(600))
        #expect(id.hasPrefix("timer:"))
        #expect(recorded)
        #expect(env.center.timers[id] == "Break")
        await env.reminders.reconcile()
        #expect(env.center.removedPending.isEmpty && env.center.removedDelivered.isEmpty)
        #expect(try env.ledger.entries().map(\.identifier).contains(id))
    }
}
