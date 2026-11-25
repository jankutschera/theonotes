// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import WidgetKit

struct CaptureActionView: View {
    let action: WidgetCaptureAction
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if family == .accessoryCircular { Image(systemName: action.symbol).font(.title2).accessibilityLabel(action.title) }
            else if family == .accessoryInline { Label(action.title, systemImage: action.symbol) }
            else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: action.symbol).font(.title)
                    Text(action.title).font(.headline).lineLimit(2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }.widgetURL(action.url())
    }
}
struct NewNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TheoNotes.NewNote", provider: StaticCaptureTimelineProvider()) { _ in
            CaptureActionView(action: .newNote).containerBackground(.background, for: .widget)
        }.configurationDisplayName("New Note").description("Start writing a new note.")
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
struct SearchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TheoNotes.Search", provider: StaticCaptureTimelineProvider()) { _ in
            CaptureActionView(action: .search).containerBackground(.background, for: .widget)
        }.configurationDisplayName("Search").description("Find a note in Theo Notes.").supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct NewTodoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TheoNotes.NewTodo", provider: StaticCaptureTimelineProvider()) { _ in
            CaptureActionView(action: .newTodo).containerBackground(.background, for: .widget)
        }.configurationDisplayName("New To-Do").description("Start a new to-do.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
struct LastOpenedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TheoNotes.LastOpened", provider: NotesTimelineProvider()) { entry in
            LastOpenedWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }.configurationDisplayName("Last Opened Note").description("Return to your last opened unprotected note.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
struct LastOpenedWidgetView: View {
    let entry: NotesWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let snapshot = entry.snapshot
        let note = snapshot?.redacted == false ? snapshot?.lastOpened : nil
        let title = note.map { $0.title.isEmpty ? "Untitled Note" : $0.title } ?? "Open Theo Notes"
        Group {
            if family == .accessoryCircular { Image(systemName: WidgetRoutes.lastOpenedSymbol(snapshot: snapshot)).accessibilityLabel(title) }
            else { Label(title, systemImage: WidgetRoutes.lastOpenedSymbol(snapshot: snapshot)).lineLimit(2) }
        }.widgetURL(WidgetRoutes.lastOpened(snapshot: snapshot))
            .privacySensitive()
    }
}
