// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import WidgetKit

private struct CaptureEntry: TimelineEntry { let date: Date }
private struct CaptureTimeline: TimelineProvider {
    func placeholder(in context: Context) -> CaptureEntry { CaptureEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (CaptureEntry) -> Void) { completion(CaptureEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptureEntry>) -> Void) {
        completion(Timeline(entries: [CaptureEntry(date: .now)], policy: .never))
    }
}
private struct CaptureComplicationView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if family == .accessoryCircular { Image(systemName: "mic").accessibilityLabel("New Theo Notes note") }
            else { Label("New note", systemImage: "mic") }
        }
        .widgetURL(WatchCaptureComplicationRoute.url)
        .containerBackground(.background, for: .widget)
    }
}
struct TheoNotesCaptureComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TheoNotes.WatchCapture", provider: CaptureTimeline()) { _ in CaptureComplicationView() }
            .configurationDisplayName("New note")
            .description("Open Theo Notes to dictate a new note.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
@main struct TheoNotesWatchWidgetBundle: WidgetBundle {
    var body: some Widget { TheoNotesCaptureComplication() }
}
