// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct NotesWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var note: NoteWidgetEntity? = nil
    var list: TagWidgetEntity? = nil
}
struct NotesTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> NotesWidgetEntry { .init(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (NotesWidgetEntry) -> Void) {
        completion(.init(date: Date(), snapshot: WidgetPublication.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NotesWidgetEntry>) -> Void) {
        let now = Date(), snapshot = WidgetPublication.read()
        let expiry = snapshot?.generatedAt.addingTimeInterval(WidgetSnapshot.lifetime) ?? now.addingTimeInterval(900)
        let dates = [now] + (snapshot?.nextUp.map(\.date).filter { $0 > now } ?? [])
        var entries = dates.map { NotesWidgetEntry(date: $0, snapshot: snapshot) }
        // At expiration the system switches to a text-free entry even if the app stays closed.
        entries.append(.init(date: max(expiry, now.addingTimeInterval(1)), snapshot: nil))
        completion(Timeline(entries: entries, policy: .after(min(expiry, now.addingTimeInterval(900)))))
    }
}
struct PinnedTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NotesWidgetEntry { .init(date: Date(), snapshot: nil) }
    func snapshot(for configuration: PinnedNoteConfiguration, in context: Context) async -> NotesWidgetEntry {
        .init(date: Date(), snapshot: WidgetPublication.read(), note: configuration.note)
    }
    func timeline(for configuration: PinnedNoteConfiguration, in context: Context) async -> Timeline<NotesWidgetEntry> {
        let entry = await snapshot(for: configuration, in: context)
        let expiry = entry.snapshot?.generatedAt.addingTimeInterval(WidgetSnapshot.lifetime) ?? entry.date.addingTimeInterval(900)
        return Timeline(entries: [entry, .init(date: max(expiry, entry.date.addingTimeInterval(1)), snapshot: nil)], policy: .after(entry.date.addingTimeInterval(900)))
    }
}
struct ListTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NotesWidgetEntry { .init(date: Date(), snapshot: nil) }
    func snapshot(for configuration: NoteListConfiguration, in context: Context) async -> NotesWidgetEntry {
        .init(date: Date(), snapshot: WidgetPublication.read(), list: configuration.list)
    }
    func timeline(for configuration: NoteListConfiguration, in context: Context) async -> Timeline<NotesWidgetEntry> {
        let entry = await snapshot(for: configuration, in: context)
        let expiry = entry.snapshot?.generatedAt.addingTimeInterval(WidgetSnapshot.lifetime) ?? entry.date.addingTimeInterval(900)
        return Timeline(entries: [entry, .init(date: max(expiry, entry.date.addingTimeInterval(1)), snapshot: nil)], policy: .after(entry.date.addingTimeInterval(900)))
    }
}
struct WidgetEmptyView: View {
    let locked: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(locked ? "Open Theo Notes" : "No note available", systemImage: locked ? "lock" : "note.text")
                .font(.headline)
            Text(locked ? "Unlock the app to continue." : "Choose a note or open the app to refresh.")
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

// Action-only widgets never read note publications or schedule data refreshes.
struct StaticCaptureEntry: TimelineEntry { let date: Date }
struct StaticCaptureTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> StaticCaptureEntry { .init(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (StaticCaptureEntry) -> Void) { completion(.init(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StaticCaptureEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: Date())], policy: .never))
    }
}
