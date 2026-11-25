// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// When each template was last used to make a note (the picker lists the recently used first).
/// Kept in `UserDefaults` by template note id: it is per-Mac UI state, not library data, so it
/// needs no migration and is not synced. Only the newest `limit` uses are kept, so the ids of
/// deleted templates fall out by themselves.
struct TemplateRecents {
    static let limit = 100
    static let key = "Templates.lastUsed"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func all() -> [String: Date] {
        let stored = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        return stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func markUsed(_ templateId: String, at date: Date) {
        var stored = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        stored[templateId] = date.timeIntervalSince1970
        if stored.count > Self.limit {
            let newest = stored.sorted { $0.value > $1.value }.prefix(Self.limit)
            stored = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        defaults.set(stored, forKey: Self.key)
    }
}
