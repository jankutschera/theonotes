// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// One window's back/forward history of visited notes (⌘[ / ⌘], inventory §2.1): browser
/// semantics, capped at `capacity` entries (the oldest are dropped).
public struct NoteHistory: Equatable, Sendable {
    public static let defaultCapacity = 100

    public let capacity: Int
    public private(set) var entries: [String] = []
    /// Position of the current entry in `entries`; nil while empty.
    public private(set) var index: Int?

    public init(capacity: Int = NoteHistory.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var current: String? { index.map { entries[$0] } }
    public var canGoBack: Bool { (index ?? 0) > 0 }
    public var canGoForward: Bool { index.map { $0 < entries.count - 1 } ?? false }

    /// Records that `id` is now shown. Visiting the current entry again is not a visit (so a
    /// selection echoing a navigation keeps the forward entries); otherwise the forward entries
    /// are dropped.
    public mutating func visit(_ id: String) {
        guard id != current else { return }
        if let index { entries.removeSubrange((index + 1)...) }
        entries.append(id)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        index = entries.count - 1
    }

    /// Moves to the nearest earlier entry `isAvailable` accepts (e.g. not deleted) and returns
    /// it; nil, without moving, when there is none.
    public mutating func goBack(where isAvailable: (String) -> Bool = { _ in true }) -> String? {
        guard let index else { return nil }
        guard let target = entries[..<index].lastIndex(where: isAvailable) else { return nil }
        self.index = target
        return entries[target]
    }

    /// Moves to the nearest later entry `isAvailable` accepts and returns it; nil, without
    /// moving, when there is none.
    public mutating func goForward(where isAvailable: (String) -> Bool = { _ in true }) -> String? {
        guard let index else { return nil }
        guard let target = entries[(index + 1)...].firstIndex(where: isAvailable) else { return nil }
        self.index = target
        return entries[target]
    }
}
