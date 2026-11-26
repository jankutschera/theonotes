// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI

/// The Info panel's content (popover or detached panel): a tab picker, then Statistics, Table of
/// Contents or Backlinks of the note the window's editor shows.
///
/// The popover is system glass (HIG: no custom popover backgrounds), so it keeps system text colours and takes
/// only the theme accent. The detached panel is an ordinary window: it draws the theme background with the
/// theme's text colours, the pair the schema checks.
struct InfoPanelView: View {
    @Bindable var info: InfoPanelModel
    /// In the floating panel: no Detach button, resizable.
    var isDetached = false

    @Environment(\.shellPalette) private var palette

    private var secondary: AnyShapeStyle {
        isDetached ? AnyShapeStyle(palette.secondaryText) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Info", selection: $info.tab) {
                    ForEach(InfoPanelModel.Tab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if !isDetached {
                    Button("Detach", systemImage: "macwindow.on.rectangle") { info.detach() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Open the Info panel in its own window")
                }
            }
            .padding(10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: isDetached ? 260 : 320, idealWidth: 320, maxWidth: isDetached ? .infinity : 320,
            minHeight: isDetached ? 260 : 400, idealHeight: 400, maxHeight: isDetached ? .infinity : 400
        )
        .tint(palette.accent)
        .modifier(DetachedSurface(isDetached: isDetached, palette: palette))
        .onAppear { info.viewAppeared() }
        .onDisappear { info.viewDisappeared() }
        .onChange(of: info.currentNoteId) { info.refresh() }
        .onChange(of: info.editor.status.selection) { if info.tab == .statistics { info.refresh() } }
    }

    @ViewBuilder
    private var content: some View {
        if info.noteId == nil {
            ContentUnavailableView("No Note Selected", systemImage: "doc.text")
        } else {
            switch info.tab {
            case .statistics: StatisticsTab(info: info)
            case .contents: ContentsTab(info: info)
            case .backlinks: BacklinksTab(info: info, secondary: secondary)
            }
        }
    }
}

/// The detached panel's own surface: the theme background and text.
private struct DetachedSurface: ViewModifier {
    let isDetached: Bool
    let palette: ShellPalette

    func body(content: Content) -> some View {
        if isDetached {
            content
                .scrollContentBackground(.hidden)
                .foregroundStyle(palette.text)
                .background(palette.background)
        } else {
            content
        }
    }
}

private struct StatisticsTab: View {
    let info: InfoPanelModel

    var body: some View {
        let stats = info.statistics
        Form {
            Section(info.isSelection ? "Selection" : "Note") {
                LabeledContent("Words") { Text(stats.words, format: .number) }
                LabeledContent("Characters") { Text(stats.characters, format: .number) }
                LabeledContent("Paragraphs") { Text(stats.paragraphs, format: .number) }
                LabeledContent("Read Time") { Text(InfoPanelModel.readTimeText(seconds: stats.readingSeconds)) }
            }
            if let lastEdit = info.lastEdit {
                Section {
                    LabeledContent("Last Edit") { Text(lastEdit, format: .dateTime) }
                }
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
    }
}

private struct ContentsTab: View {
    let info: InfoPanelModel

    var body: some View {
        if info.headings.isEmpty {
            ContentUnavailableView("No Headings", systemImage: "list.bullet.indent")
        } else {
            List(Array(info.headings.enumerated()), id: \.offset) { index, heading in
                Button { info.scrollToHeading(index) } label: {
                    Text(heading.text)
                        .fontWeight(heading.level <= 2 ? .semibold : .regular)
                        .lineLimit(1)
                        .padding(.leading, CGFloat(heading.level - 1) * 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct BacklinksTab: View {
    let info: InfoPanelModel
    let secondary: AnyShapeStyle
    @State private var linkedExpanded = true
    @State private var unlinkedExpanded = true

    var body: some View {
        let backlinks = info.backlinks
        List {
            Section(isExpanded: $linkedExpanded) {
                if backlinks.linked.isEmpty {
                    Text("No linked mentions").foregroundStyle(secondary)
                }
                ForEach(backlinks.linked) { note in
                    MentioningNoteRow(info: info, note: note, canLink: false, secondary: secondary)
                }
                if let footer = InfoPanelModel.linkedFooter(backlinks) {
                    Text(footer).font(.caption).foregroundStyle(secondary)
                }
            } header: {
                Text("Linked Mentions (\(backlinks.linked.count))")
            }
            Section(isExpanded: $unlinkedExpanded) {
                if backlinks.unlinked.isEmpty {
                    Text("No unlinked mentions").foregroundStyle(secondary)
                }
                ForEach(backlinks.unlinked) { note in
                    MentioningNoteRow(
                        info: info, note: note, canLink: backlinks.canLink && note.canLink, secondary: secondary)
                }
                if let footer = InfoPanelModel.unlinkedFooter(backlinks) {
                    Text(footer).font(.caption).foregroundStyle(secondary)
                }
            } header: {
                Text("Unlinked Mentions (\(backlinks.unlinked.count))")
            }
        }
        .listStyle(.sidebar)
    }
}

/// A note with its mentions, collapsible (Bear: per-note disclosure). Clicking the title opens it.
private struct MentioningNoteRow: View {
    let info: InfoPanelModel
    let note: MentioningNote
    let canLink: Bool
    let secondary: AnyShapeStyle
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(note.mentions) { mention in
                HStack(alignment: .firstTextBaseline) {
                    Text(mention.snippet)
                        .font(.callout)
                        .foregroundStyle(secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if canLink {
                        Button("Link") { info.link(mention) }
                            .controlSize(.small)
                            .help("Make this mention a wiki link to the note")
                    }
                }
            }
        } label: {
            Button { info.open(note.noteId) } label: {
                Label(note.isLocked ? "Locked Note" : (note.title.isEmpty ? "Untitled" : note.title),
                      systemImage: note.isLocked ? "lock" : "doc.text")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        }
    }
}
