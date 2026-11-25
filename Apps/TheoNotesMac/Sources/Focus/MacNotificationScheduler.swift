// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import UserNotifications
import os

private let reminderLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "reminders")

/// Applies the reminder plan to the notification center (FOC-R10, FOC-R17, FOC-R260 … FOC-R265). It
/// decides nothing about content: `PingPlanner` plans, `NotificationLedger` matches the plan against
/// what was scheduled, and this class adds, removes and reads back. Log lines carry counts only.
@MainActor
final class MacNotificationScheduler {
    /// At most this many notifications are scheduled at once (parity with iOS, FOC-R260).
    static let scheduleCap = 64

    /// What setting a reminder came to.
    enum Outcome: Equatable {
        case scheduled
        /// The reminder is saved; the Mac will not show notifications for it until they are allowed.
        case notificationsOff
    }

    private weak var environment: AppEnvironment?
    private let center: any NotificationCenterClient
    private let now: () -> Date
    private let calendar: Calendar

    /// Shows a note, with the caret at `caret` (UTF-16) when given. True when it was shown; a tap
    /// that could not open the note (App Lock is engaged) leaves its reminder in place (FOC-R261).
    var openNote: (_ noteId: String, _ caret: Int?) -> Bool = { _, _ in false }

    private var inFlight: Task<Void, Never>?
    private var rerun = false
    private var sweepRequested = false

    init(
        environment: AppEnvironment, center: any NotificationCenterClient,
        now: @escaping () -> Date = { .now }, calendar: Calendar = .current
    ) {
        self.environment = environment
        self.center = center
        self.now = now
        self.calendar = calendar
        center.registerCategories()
    }

    private var ledger: NotificationLedger? { environment.map { NotificationLedger(store: $0.store) } }

    // MARK: Cold launch

    /// Removes, by id and without enumerating, the notifications of every locked or deleted note, and
    /// of all reminders while App Lock is enabled (FOC-R17). Synchronous: it runs during library
    /// initialization, before any window exists, and when App Lock is turned on.
    func coldLaunchScrub() {
        guard let environment, let ledger else { return }
        do {
            let ids = try ledger.coldLaunchRemovals(appLockEnabled: environment.appLock.isEnabled)
            guard !ids.isEmpty else { return }
            center.removeDeliveredNow(ids)
            center.removePendingNow(ids)
            reminderLogger.notice("scrub: \(ids.count) reminder id(s) removed")
        } catch {
            reminderLogger.error("scrub: the ledger could not be read")
        }
    }

    // MARK: Reconcile

    /// Brings the notification center in line with the plan. Calls made while a pass is running join
    /// it and make it run once more, so a change that lands mid-pass is never missed. `sweep: false`
    /// (a note was typed in) enumerates the center only when something was added or removed.
    func reconcile(sweep: Bool = true) async {
        if sweep { sweepRequested = true }
        if let inFlight {
            rerun = true
            await inFlight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var passes = 0
            repeat {
                rerun = false
                if await reconcileOnce(), passes == 0 { rerun = true }
                passes += 1
            } while rerun
            inFlight = nil
        }
        inFlight = task
        await task.value
    }

    /// One pass. True when the readback forgot a row the plan still wanted: the notification was not
    /// in the center (a crash between record and add, or a failed add), so one more pass adds it.
    private func reconcileOnce() async -> Bool {
        guard let environment, let ledger else { return false }
        let store = environment.store
        let sweepNow = sweepRequested
        sweepRequested = false
        let authorized = await center.isAuthorized()
        let current = now()
        do {
            let appLock = environment.appLock.isEnabled
            // Denied: nothing is planned, so nothing stays scheduled; the reminders themselves are kept.
            let planned = authorized
                ? Array(try PingPlanner.plan(store: store, appLockEnabled: appLock, now: current).prefix(Self.scheduleCap))
                : []
            if !sweepNow, planned.isEmpty, try ledger.entries().isEmpty { return false }

            let (add, remove) = try ledger.reconcile(planned: planned, now: current)
            let known = Dictionary(try ledger.entries().map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            // A banner the person has not dealt with yet stays (FOC-R262); so does a due request the
            // Mac has not delivered yet, as long as it still says what the plan would say (FOC-R266).
            var kept = Set<String>()
            if !remove.isEmpty {
                let delivered = Set(await center.deliveredIdentifiers())
                let pending = await center.pendingIdentifiers()
                let currentHashes = Dictionary(
                    try PingPlanner.plan(store: store, appLockEnabled: appLock, now: Date(timeIntervalSince1970: 0)).map { ($0.pingId, $0.contentHash) },
                    uniquingKeysWith: { first, _ in first })
                for id in remove {
                    guard let entry = known[id], isKeepable(entry, store: store, now: current, appLockEnabled: appLock) else { continue }
                    if delivered.contains(id) {
                        kept.insert(id)
                    } else if pending.contains(id), let pingId = entry.pingId, let hash = entry.contentHash,
                              currentHashes[pingId] == hash, let ping = (try? store.ping(id: pingId)) ?? nil, ping.firedAt == nil {
                        kept.insert(id)
                    }
                }
            }
            let waiting = kept
            let stale = remove.filter { !waiting.contains($0) }
            if !stale.isEmpty {
                center.removePending(stale)
                center.removeDelivered(stale)
            }
            var failed = 0
            for item in add {
                do {
                    try await center.add(item.notification, identifier: item.identifier)
                } catch {
                    failed += 1
                }
            }
            reminderLogger.notice("reconcile: \(add.count) added (\(failed) failed), \(stale.count) removed, \(waiting.count) kept delivered")
            guard sweepNow || !add.isEmpty || !remove.isEmpty else { return false }
            return await sweepAndReadBack(ledger: ledger, retired: Set(remove))
        } catch {
            reminderLogger.error("reconcile failed")
            return false
        }
    }

    /// The second line (FOC-R17): removes `reminder:` ids no ledger row knows, enumerates again, and
    /// forgets the rows whose notification is gone. Runs only after every add has completed.
    private func sweepAndReadBack(ledger: NotificationLedger, retired: Set<String>) async -> Bool {
        let pending = await center.pendingIdentifiers()
        let delivered = Set(await center.deliveredIdentifiers())
        let unknown = ledger.sweepUnknown(pending: pending, delivered: delivered)
        if !unknown.isEmpty {
            center.removePending(unknown)
            center.removeDelivered(unknown)
        }
        let pendingAfter = await center.pendingIdentifiers()
        let deliveredAfter = Set(await center.deliveredIdentifiers())
        do {
            let before = Set(try ledger.entries().map(\.identifier))
            try ledger.confirmGone(pending: pendingAfter, delivered: deliveredAfter)
            let after = Set(try ledger.entries().map(\.identifier))
            let forgotten = before.subtracting(after)
            reminderLogger.notice("sweep: \(unknown.count) unknown removed, \(forgotten.count) forgotten")
            return !forgotten.subtracting(retired).isEmpty
        } catch {
            reminderLogger.error("readback failed")
            return false
        }
    }

    /// A due or fired reminder on a note that is still open to the app and shows no text it should
    /// not: the notification stays until the user taps or dismisses it (if it is delivered) or the
    /// Mac delivers it (if it is still pending and unchanged).
    private func isKeepable(_ entry: LedgerEntry, store: NoteStore, now: Date, appLockEnabled: Bool) -> Bool {
        guard !appLockEnabled, entry.kind == .reminder, entry.contentHash != nil,
              let pingId = entry.pingId, let noteId = entry.noteId,
              let ping = (try? store.ping(id: pingId)) ?? nil, ping.firedAt != nil || ping.fireAt <= now,
              let note = (try? store.note(id: noteId)) ?? nil,
              !note.isLocked, note.location == .notes, note.deletedAt == nil
        else { return false }
        return true
    }

    // MARK: Setting, launch and activation

    /// Sets the reminder and schedules it. The first call asks for permission (the system prompts
    /// once); a refusal keeps the reminder and schedules nothing (FOC-R263).
    @discardableResult
    func setReminder(noteId: String, anchor: LineAnchor?, fireAt: Date) async throws -> Outcome {
        guard let environment else { return .notificationsOff }
        let granted = await center.requestAuthorization()
        try environment.store.setPing(noteId: noteId, anchor: anchor, fireAt: fireAt, now: now())
        await reconcile()
        return granted ? .scheduled : .notificationsOff
    }

    /// Launch and every activation: a reminder that came due while the app was not in front is
    /// marked fired (it stays until handled), then the center is reconciled (FOC-R264).
    func catchUp() async {
        guard let environment else { return }
        do {
            _ = try environment.store.markPingsFired(dueBy: now())
        } catch {
            reminderLogger.error("catch-up could not mark reminders")
        }
        await reconcile()
    }

    /// A timer notification (the Next Up timer). Its id is recorded before it is added, like a
    /// reminder's, and the ledger never removes it by itself (FOC-R265).
    @discardableResult
    func scheduleTimer(title: String, at date: Date) async throws -> String {
        guard let ledger else { throw CancellationError() }
        let identifier = "timer:\(UUID().uuidString.lowercased())"
        try ledger.record(LedgerEntry(identifier: identifier, kind: .timer, pingId: nil, noteId: nil, contentHash: nil), now: now())
        try await center.addTimer(identifier: identifier, title: title, at: date)
        return identifier
    }

    // MARK: The Next Up timer (FOC-R282)

    /// Timer notifications whose end a Next Up panel may show itself. Each answers, when the notification arrives, whether the panel that owns the timer would
    /// open for its end right now (in front, unlocked, key window); only then the banner is skipped.
    private var panelTimers: [String: () -> Bool] = [:]

    /// Schedules the notification for a Next Up timer ending at `date`. Asks for permission first,
    /// like a reminder (the system prompts once); nil when notifications are off or the request
    /// failed, in which case the timer only counts on the card.
    func startPanelTimer(title: String, at date: Date, panelShowsTheEnd: @escaping () -> Bool) async -> String? {
        guard await center.requestAuthorization() else { return nil }
        guard let identifier = try? await scheduleTimer(title: title, at: date) else { return nil }
        panelTimers[identifier] = panelShowsTheEnd
        return identifier
    }

    /// Takes a Next Up timer's notification away, pending or delivered, and forgets its ledger row.
    func cancelTimer(_ identifier: String) {
        panelTimers[identifier] = nil
        center.removePendingNow([identifier])
        center.removeDeliveredNow([identifier])
        do {
            try ledger?.forget([identifier])
        } catch {
            reminderLogger.error("timer: the ledger row could not be forgotten")
        }
    }

    // MARK: The delegate

    /// The reminder id behind a notification identifier: the ledger's, else the id's own shape.
    private func pingId(for requestIdentifier: String, ledger: NotificationLedger) -> (pingId: String?, noteId: String?)? {
        guard requestIdentifier.hasPrefix("reminder:") else { return nil }
        if let entry = (try? ledger.entries())?.first(where: { $0.identifier == requestIdentifier }) {
            return (entry.pingId, entry.noteId)
        }
        let parts = requestIdentifier.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 ? (String(parts[1]), nil) : (nil, nil)
    }

    func handle(actionIdentifier: String, requestIdentifier: String) async {
        guard let environment, let ledger, let ids = pingId(for: requestIdentifier, ledger: ledger) else { return }
        let store = environment.store
        let ping = ids.pingId.flatMap { (try? store.ping(id: $0)) ?? nil }
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            let noteId = ping?.noteId ?? ids.noteId
            var opened = false
            if let noteId {
                opened = openNote(noteId, caret(for: ping, noteId: noteId, store: store))
            }
            // Not opened (App Lock is engaged): the reminder stays, and Next Up still offers it.
            if opened || noteId == nil, let ping { try? store.handlePing(id: ping.id) }
        case UNNotificationDismissActionIdentifier:
            if let ping { try? store.handlePing(id: ping.id) }
        case NotificationLedger.snoozeHourAction:
            if let ping { _ = try? store.snoozePing(id: ping.id, until: PingTime.inOneHour(now: now()), now: now()) }
        case NotificationLedger.snoozeNineAction:
            if let ping {
                let until = PingTime.defaultFireDate(now: now(), calendar: calendar)
                _ = try? store.snoozePing(id: ping.id, until: until, now: now())
            }
        default:
            return
        }
        await reconcile()
    }

    /// The caret (UTF-16) of the reminder's line in the note as it is now; nil for a whole-note
    /// reminder, a line that is gone, or a locked note.
    private func caret(for ping: Ping?, noteId: String, store: NoteStore) -> Int? {
        guard let anchor = ping?.anchor, let note = (try? store.note(id: noteId)) ?? nil, !note.isLocked,
              let line = anchor.resolve(in: note.text)
        else { return nil }
        return LineAnchor.utf16Offset(ofLine: line, in: note.text)
    }

    /// Whether a notification that arrives while the app is in front is shown (FOC-R266). Decided
    /// from the library as it is now, synchronously, because the notification was written earlier:
    /// - a timer is shown, unless the Next Up panel runs it and shows its end itself (FOC-R282);
    /// - a reminder is shown only if its reminder still exists, its note is unlocked, in Notes and
    ///   not deleted, and, while App Lock is enabled, only if it was scheduled with the generic text;
    /// - anything else is not shown, is removed by id (pending and delivered) and, when its reminder
    ///   still exists, marked fired: it is due now, and Next Up still offers it. Nothing replaces it
    ///   (a fired reminder is not planned again); reminders that are not due yet are replanned redacted.
    func willPresent(requestIdentifier: String) -> Bool {
        guard let environment, let ledger,
              let entry = (try? ledger.entries())?.first(where: { $0.identifier == requestIdentifier })
        else { return false }
        // A timer whose panel would open for its end shows it there; any other banners (a timer of an
        // earlier launch, or one whose window is not the key window).
        if entry.kind == .timer { return !(panelTimers[requestIdentifier]?() ?? false) }
        let store = environment.store
        let ping = entry.pingId.flatMap { (try? store.ping(id: $0)) ?? nil }
        if let ping, isSafeToPresent(entry, ping: ping, store: store, appLockEnabled: environment.appLock.isEnabled) {
            try? store.markPingFired(id: ping.id, at: now())
            return true
        }
        if let ping { try? store.markPingFired(id: ping.id, at: now()) }
        center.removeDeliveredNow([requestIdentifier])
        center.removePendingNow([requestIdentifier])
        reminderLogger.notice("a reminder was not shown: its note or the App Lock setting changed")
        Task { [weak self] in await self?.reconcile() }
        return false
    }

    private func isSafeToPresent(_ entry: LedgerEntry, ping: Ping, store: NoteStore, appLockEnabled: Bool) -> Bool {
        guard let note = (try? store.note(id: ping.noteId)) ?? nil,
              !note.isLocked, note.location == .notes, note.deletedAt == nil
        else { return false }
        guard appLockEnabled else { return true }
        // The row's hash says what was scheduled; only the generic form of this very reminder may show.
        guard let hash = entry.contentHash,
              let generic = try? PingPlanner.plan(store: store, appLockEnabled: true, now: Date(timeIntervalSince1970: 0))
                  .first(where: { $0.pingId == ping.id })
        else { return false }
        return generic.contentHash == hash
    }
}
