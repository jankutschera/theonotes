// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import WidgetKit

struct NextUpWidget: Widget {
    let kind = "TheoNotes.NextUp"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NotesTimelineProvider()) { entry in
            NextUpWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }.configurationDisplayName("Next Up").description("Your next reminder, to-do or thought.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}
struct NextUpWidgetView: View {
    let entry: NotesWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let next = entry.snapshot?.nextUpEntry(at: entry.date)
        let candidate = next?.state == .candidate
        let title = WidgetRoutes.nextUpTitle(snapshot: entry.snapshot, at: entry.date)
        let symbol = WidgetRoutes.nextUpSymbol(snapshot: entry.snapshot, at: entry.date)
        Group {
            switch family {
            case .accessoryInline:
                Label(title, systemImage: symbol)
            case .accessoryCircular:
                Image(systemName: symbol).font(.title2).accessibilityLabel(title)
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Next Up", systemImage: symbol).font(.caption)
                    Text(title).font(.headline).lineLimit(2)
                    if candidate, let line = next?.line, family != .accessoryRectangular {
                        Text(line).font(.body).lineLimit(family == .systemLarge ? 8 : 3)
                    }
                    if family != .accessoryRectangular { Spacer(minLength: 0) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.widgetURL(WidgetRoutes.nextUp(snapshot: entry.snapshot, at: entry.date))
            .privacySensitive()
    }
}
