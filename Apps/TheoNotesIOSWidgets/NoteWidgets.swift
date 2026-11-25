// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import WidgetKit

struct PinnedNoteWidget: Widget {
    let kind = "TheoNotes.PinnedNote"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: PinnedNoteConfiguration.self, provider: PinnedTimelineProvider()) { entry in
            PinnedNoteWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }.configurationDisplayName("Pinned Note").description("Keep a chosen note close.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
struct PinnedNoteWidgetView: View {
    let entry: NotesWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let snapshot = entry.snapshot
        let note = snapshot?.selectedPinnedNote(entityID: entry.note?.id)
        Group {
            if let note, let snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Pinned Note", systemImage: "pin").font(.caption).foregroundStyle(.secondary)
                    Text(note.title.isEmpty ? "Untitled Note" : note.title).font(.headline).lineLimit(family == .systemSmall ? 2 : 3)
                    Text(note.firstLine).font(.body).lineLimit(family == .systemLarge ? 10 : 3)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .widgetURL(WidgetRoutes.note(note.id, libraryID: snapshot.libraryID))
                    .privacySensitive()
            } else { WidgetEmptyView(locked: snapshot?.redacted ?? false) }
        }
    }
}
struct NoteListWidget: Widget {
    let kind = "TheoNotes.NoteList"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: NoteListConfiguration.self, provider: ListTimelineProvider()) { entry in
            NoteListWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }.configurationDisplayName("Tag or Inbox").description("See notes from a tag or your Inbox.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
struct NoteListWidgetView: View {
    let entry: NotesWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let snapshot = entry.snapshot
        let parts = entry.list?.parts
        let notes = snapshot?.selectedList(entityID: entry.list?.id) ?? []
        let limit = family == .systemSmall ? 2 : family == .systemMedium ? 3 : 7
        Group {
            if let snapshot, !snapshot.redacted, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(parts?.tag.map { "#" + $0 } ?? "Inbox").font(.headline).lineLimit(1)
                    ForEach(Array(notes.prefix(limit))) { note in
                        Link(destination: WidgetRoutes.note(note.id, libraryID: snapshot.libraryID)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title.isEmpty ? "Untitled Note" : note.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if family != .systemSmall { Text(note.firstLine).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                }.privacySensitive()
            } else { WidgetEmptyView(locked: snapshot?.redacted ?? false) }
        }
    }
}
