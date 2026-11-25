// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Runs an action after a delay unless it is cancelled first. Injected so tests control time.
@MainActor
public protocol DebounceScheduler: AnyObject {
    /// Time since an arbitrary fixed start (for "how long ago").
    var now: Duration { get }
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledAction
}

@MainActor
public final class ScheduledAction {
    private var onCancel: (@MainActor () -> Void)?

    public init(cancel: @escaping @MainActor () -> Void) {
        onCancel = cancel
    }

    public func cancel() {
        onCancel?()
        onCancel = nil
    }
}

/// The app's scheduler: a main-actor task sleeping on the continuous clock.
@MainActor
public final class TaskDebounceScheduler: DebounceScheduler {
    private let start = ContinuousClock.now

    public init() {}

    public var now: Duration { start.duration(to: .now) }

    public func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledAction {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            action()
        }
        return ScheduledAction { task.cancel() }
    }
}

/// Debounces Bear's wiki link name update (spec §3.5) for the notes shown in an editor.
///
/// Only title (and heading) edits made in Theo Notes' editor are followed (ruling R15):
/// the monitor listens to the notes' `NoteSession` activity. A session commit carries the
/// editor's typing; an `externalChange` (CLI/MCP, import or pull, tag rename, another process,
/// the rewrite itself) only moves the baseline along. A commit that merges an external change is
/// preceded by that change alone, so only the editor's part counts. This is more robust than
/// comparing store revisions: every external change reaches the session before any commit built
/// on it, and nothing depends on observation timing.
///
/// Once a note's title and headings have stayed the same for `delay` after they last changed,
/// `rewrite` gets the note's state from before the change. Typing a title therefore never
/// rewrites on every keystroke.
@MainActor
public final class TitleChangeMonitor {
    public static let delay: Duration = .milliseconds(1500)
    /// An editor must have applied no transaction for this long before a rewrite may change its
    /// note: keystrokes it sent meanwhile could otherwise arrive on the old revision and be lost.
    static let idle: Duration = .milliseconds(500)
    /// After deferring this long (an editor that never pauses), the rewrite goes through anyway,
    /// through the sessions as on close and quit.
    static let maxDeferral: Duration = .seconds(5)

    private struct Tracked {
        /// The note as links last matched it: the state before a pending change.
        var stable: LinkTargetState
        /// The latest state seen.
        var lastSeen: LinkTargetState
        var pending: ScheduledAction?
        /// Bumped by every (re)schedule and reset, so a superseded timer does nothing.
        var generation = 0
        /// When the rewrite was first deferred for a busy editor (cleared once it ran).
        var deferredSince: Duration?
    }

    private let scheduler: any DebounceScheduler
    private let read: (String) -> LinkTargetState?
    private let flush: () -> Void
    /// Rewrites the links to a note from its previous state, unless it would change a note in
    /// `busy`; returns false when it deferred.
    private let rewrite: (_ noteId: String, _ previous: LinkTargetState, _ busy: Set<String>) -> Bool
    private var tracked: [String: Tracked] = [:]
    private var watched: Set<String> = []
    /// When each note's editor last applied a transaction (`scheduler.now`).
    private var lastEdit: [String: Duration] = [:]

    public init(
        scheduler: any DebounceScheduler,
        read: @escaping (String) -> LinkTargetState?,
        flush: @escaping () -> Void,
        rewrite: @escaping (_ noteId: String, _ previous: LinkTargetState, _ busy: Set<String>) -> Bool
    ) {
        self.scheduler = scheduler
        self.read = read
        self.flush = flush
        self.rewrite = rewrite
    }

    public var hasPendingRewrites: Bool { tracked.values.contains { $0.pending != nil } }

    /// The notes shown now. One that stops being shown is looked at once more after `delay` (its
    /// last typing may not be committed yet), then forgotten.
    public func watch(_ ids: Set<String>) {
        for id in ids where tracked[id] == nil {
            if let state = read(id) { tracked[id] = Tracked(stable: state, lastSeen: state) }
        }
        for id in watched.subtracting(ids) where tracked[id] != nil && tracked[id]?.pending == nil {
            schedule(id)
        }
        watched = ids
    }

    /// What a note's session reported (`AppEnvironment` forwards every session's activity).
    public func sessionActivity(_ noteId: String, _ activity: NoteSession.Activity) {
        switch activity {
        case .edited:
            pruneEdits()
            lastEdit[noteId] = scheduler.now
        case .committed(let text, let modifiedAt):
            guard var entry = tracked[noteId] else { return }
            let current = LinkTargetState(text: text, modifiedAt: modifiedAt)
            let changed = current.changeKey != entry.lastSeen.changeKey
            entry.lastSeen = current
            if !changed && entry.pending == nil { entry.stable = Self.advanced(entry.stable, to: current) }
            tracked[noteId] = entry
            if changed { schedule(noteId) }
        case .externalChange(let previous, let text, let modifiedAt):
            guard var entry = tracked[noteId] else { return }
            let after = LinkTargetState(text: text, modifiedAt: modifiedAt)
            if LinkTargetState(text: previous, modifiedAt: modifiedAt).changeKey != after.changeKey {
                // Renamed elsewhere (R15): not followed, and a pending editor rename is superseded.
                entry.pending?.cancel()
                entry.pending = nil
                entry.deferredSince = nil
                entry.generation += 1
                entry.stable = after
            } else if entry.pending == nil {
                entry.stable = Self.advanced(entry.stable, to: after)
            }
            entry.lastSeen = after
            tracked[noteId] = entry
            if entry.pending == nil && !watched.contains(noteId) { forget(noteId) }
        }
    }

    /// App termination or window close: flushes and runs every pending rewrite now, busy
    /// editors included (nothing more will arrive from them).
    public func runPendingNow() {
        flush()  // typing not committed yet may hold a title change that is not pending yet
        for id in tracked.keys.sorted() where tracked[id]?.pending != nil {
            fire(id, generation: nil)
        }
    }

    private func schedule(_ id: String, after delay: Duration = TitleChangeMonitor.delay) {
        guard var entry = tracked[id] else { return }
        entry.pending?.cancel()
        entry.generation += 1
        let generation = entry.generation
        entry.pending = scheduler.schedule(after: delay) { [weak self] in self?.fire(id, generation: generation) }
        tracked[id] = entry
    }

    private func forget(_ id: String) {
        tracked[id]?.pending?.cancel()
        tracked[id] = nil
    }

    /// `generation` nil: forced (termination) — no waiting for a newer title or an idle editor.
    private func fire(_ id: String, generation: Int?) {
        guard let entry = tracked[id], generation == nil || entry.generation == generation else { return }
        // Commits this flush makes arrive as activity: a newer title reschedules (bumping the
        // generation), a rename elsewhere resets the entry.
        flush()
        guard var entry = tracked[id] else { return }
        if let generation, entry.generation != generation { return }
        entry.pending?.cancel()
        entry.pending = nil
        tracked[id] = entry
        guard read(id) != nil else {
            forget(id)
            return
        }
        if entry.lastSeen.changeKey != entry.stable.changeKey {
            pruneEdits()
            let overdue = entry.deferredSince.map { scheduler.now - $0 >= Self.maxDeferral } ?? false
            let busy = generation == nil || overdue ? [] : Set(lastEdit.keys)
            if !rewrite(id, entry.stable, busy) {
                tracked[id]?.deferredSince = entry.deferredSince ?? scheduler.now
                schedule(id, after: Self.idle)
                return
            }
        }
        tracked[id]?.deferredSince = nil
        // The rewrite's own edits came back as external changes and are already in `lastSeen`.
        if let current = tracked[id], current.pending == nil {
            tracked[id]?.stable = Self.advanced(current.stable, to: current.lastSeen)
        }
        if !watched.contains(id) { forget(id) }
    }

    /// Edits older than `idle` no longer make an editor busy.
    private func pruneEdits() {
        let now = scheduler.now
        lastEdit = lastEdit.filter { now - $0.value < Self.idle }
    }

    /// The baseline after a change. An emptied title is not adopted: links still name the old one,
    /// and the next title takes them over ("Old" → "" → "New" rewrites `[[Old]]`). Likewise a
    /// heading that was emptied is kept — only while an empty heading line of its level is still
    /// in the text (`## ` being retyped), so retyping it renames it while a real deletion moves the
    /// baseline on.
    private static func advanced(_ stable: LinkTargetState, to current: LinkTargetState) -> LinkTargetState {
        var next = current
        if current.title.isEmpty && !stable.title.isEmpty {
            next.title = stable.title
            next.modifiedAt = stable.modifiedAt
        }
        if let removed = removedIndex(from: stable.headings, giving: current.headings),
           stable.headingLevels.indices.contains(removed),
           current.emptyHeadingLevels.contains(stable.headingLevels[removed]) {
            next.headings = stable.headings
            next.headingLevels = stable.headingLevels
        }
        return next
    }

    /// The index of the one heading `old` lost to become `new` (the rest unchanged), if so.
    private static func removedIndex(from old: [String], giving new: [String]) -> Int? {
        guard old.count == new.count + 1 else { return nil }
        let oldKeys = old.map(CanonicalKey.make), newKeys = new.map(CanonicalKey.make)
        return oldKeys.indices.first { index in
            var rest = oldKeys
            rest.remove(at: index)
            return rest == newKeys
        }
    }
}
