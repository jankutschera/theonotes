// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// One numeric typography control: its range, step and how its value reads. The ranges are narrower than
/// the bridge protocol's (`TypographySettings.*Range`), which stays the hard limit.
enum TypographyField: CaseIterable, Identifiable {
    case fontSize, lineHeight, lineWidth, paragraphSpacing, paragraphIndent

    var id: Self { self }

    var keyPath: WritableKeyPath<TypographySettings, Double> {
        switch self {
        case .fontSize: \.fontSize
        case .lineHeight: \.lineHeight
        case .lineWidth: \.lineWidth
        case .paragraphSpacing: \.paragraphSpacing
        case .paragraphIndent: \.paragraphIndent
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .fontSize: 10...40
        case .lineHeight: 1.0...2.5
        case .lineWidth: 400...1600
        case .paragraphSpacing: 0...2
        case .paragraphIndent: 0...4
        }
    }

    var step: Double {
        switch self {
        case .fontSize: 1
        case .lineHeight: 0.1
        case .lineWidth: 20
        case .paragraphSpacing: 0.1
        case .paragraphIndent: 0.5
        }
    }

    var title: String {
        switch self {
        case .fontSize: "Font size"
        case .lineHeight: "Line height"
        case .lineWidth: "Line width"
        case .paragraphSpacing: "Paragraph spacing"
        case .paragraphIndent: "Paragraph indentation"
        }
    }

    /// `value` moved to the nearest step from the range's start, inside the range, without float noise
    /// (0.1 + 0.2 stores 0.3, not 0.30000000000000004), so what is stored equals what the label shows.
    func snapped(_ value: Double) -> Double {
        guard !value.isNaN else { return range.lowerBound }
        let steps = ((value - range.lowerBound) / step).rounded()
        let moved = range.lowerBound + steps * step
        let clean = (moved * 1_000_000).rounded() / 1_000_000
        return min(max(clean, range.lowerBound), range.upperBound)
    }

    /// "16 pt", "1.6", "720 pt", "0.4 em", "0 em".
    func format(_ value: Double) -> String {
        switch self {
        case .fontSize: "\(Int(value.rounded())) pt"
        case .lineHeight: String(format: "%.1f", value)
        case .lineWidth: "\(Int(value.rounded())) pt"
        case .paragraphSpacing, .paragraphIndent: "\(String(format: "%g", (value * 10).rounded() / 10)) em"
        }
    }
}

/// The font families the pickers offer: installed, and a name the editor accepts
/// (`EditorTypography.isValidFontFamily`), so the user cannot pick one the bridge would drop.
@MainActor
enum FontFamilies {
    struct Lists: Equatable {
        var text: [String]
        var code: [String]
    }

    private static var cache: Lists?

    /// Both lists from one enumeration, kept until `invalidateCache()` (the enumeration is slow, and a pane
    /// must not pay for it on every render).
    static func lists() -> Lists {
        if let cache { return cache }
        let read = read(NSFontManager.shared.availableFontFamilies)
        cache = read
        return read
    }

    static func invalidateCache() { cache = nil }

    /// Whether the lists are held (tests).
    static var isCached: Bool { cache != nil }

    static func text() -> [String] { lists().text }

    /// Fixed-pitch families first, then the rest, each part sorted.
    static func code() -> [String] { lists().code }

    private static func read(_ available: [String]) -> Lists {
        let text = usable(available)
        var fixed = Set<String>()
        for name in NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [] {
            if let family = NSFont(name: name, size: 12)?.familyName { fixed.insert(family) }
        }
        return Lists(text: text, code: text.filter(fixed.contains) + text.filter { !fixed.contains($0) })
    }

    /// Valid for the bridge, not one of the system's hidden families (".SF NS"), sorted the way Finder sorts.
    nonisolated static func usable(_ families: [String]) -> [String] {
        families
            .filter { !$0.hasPrefix(".") && EditorTypography.isValidFontFamily($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Writes a dragged value through at most once per `interval`, and the last value after the pause or at the
/// end of the drag, so a drag does not send a message to every editor on every step.
@MainActor
final class WriteCoalescer {
    private let interval: Duration
    private let clock = ContinuousClock()
    private var lastWrite: ContinuousClock.Instant?
    private var pending: (value: Double, write: (Double) -> Void)?
    private var trailing: Task<Void, Never>?

    init(interval: Duration = .milliseconds(100)) {
        self.interval = interval
    }

    /// A value during a drag: written now when the last write is older than `interval`, else after the rest of it.
    func update(_ value: Double, write: @escaping (Double) -> Void) {
        let now = clock.now
        if let lastWrite, now - lastWrite < interval {
            pending = (value, write)
            if trailing == nil {
                let wait = interval - (now - lastWrite)
                trailing = Task { [weak self] in
                    try? await Task.sleep(for: wait)
                    guard !Task.isCancelled else { return }
                    self?.flushPending()
                }
            }
        } else {
            cancelTrailing()
            lastWrite = now
            write(value)
        }
    }

    /// The final value (the drag ended): always written, and nothing stays pending.
    func finish(_ value: Double, write: (Double) -> Void) {
        cancelTrailing()
        lastWrite = nil
        write(value)
    }

    private func flushPending() {
        trailing = nil
        guard let (value, write) = pending else { return }
        pending = nil
        lastWrite = clock.now
        write(value)
    }

    private func cancelTrailing() {
        trailing?.cancel()
        trailing = nil
        pending = nil
    }
}

/// One entry of a font picker.
struct FontOption: Identifiable, Equatable {
    /// The stored family ("" is the default font).
    let id: String
    let label: String
    let isMissing: Bool
}

enum FontOptions {
    /// "Default" first, then `families`. A stored family that is not among them stays selectable as
    /// "Default (<name> missing)" so the picker shows what is stored (the editor uses its default font).
    static func options(families: [String], stored: String) -> [FontOption] {
        var result = [FontOption(id: "", label: "Default", isMissing: false)]
        if !stored.isEmpty, !families.contains(stored) {
            result.append(FontOption(id: stored, label: "Default (\(stored) missing)", isMissing: true))
        }
        result += families.map { FontOption(id: $0, label: $0, isMissing: false) }
        return result
    }
}

extension SettingsModel {
    /// Typography > Restore Defaults: the fonts and every number.
    func restoreTypographyDefaults() {
        set(.typography, .default)
    }
}

/// Settings > Typography. Writes `typography`; `AppearanceController` sends it to every editor.
struct TypographySettingsPane: View {
    let settings: SettingsModel

    /// Bumped when the installed fonts change, so the lists are read again.
    @State private var fontSetGeneration = 0
    @State private var fontsObserver: InstalledFontsObserver?

    var body: some View {
        let typography = settings.snapshot.typography
        let _ = fontSetGeneration
        let lists = FontFamilies.lists()
        let textFamilies = lists.text
        let codeFamilies = lists.code
        Form {
            Section {
                fontPicker("Text font", stored: typography.fontText, families: textFamilies, field: \.fontText)
                fontPicker("Heading font", stored: typography.fontHeading, families: textFamilies, field: \.fontHeading)
                fontPicker("Code font", stored: typography.fontCode, families: codeFamilies, field: \.fontCode)
            } header: {
                Text("Fonts")
            } footer: {
                Text("Heading font: Default follows the text font.")
                    .foregroundStyle(.secondary)
            }
            Section("Layout") {
                ForEach(TypographyField.allCases) { field in
                    row(field, typography: typography)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { settings.restoreTypographyDefaults() }
                        .disabled(typography == .default)
                        .accessibilityHint("Resets the fonts, size, spacing and width")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // The same events as `AppearanceController`; a font installed while Settings is open shows up.
            fontsObserver = InstalledFontsObserver {
                FontFamilies.invalidateCache()
                fontSetGeneration += 1
            }
        }
    }

    private func fontPicker(
        _ title: String, stored: String, families: [String], field: WritableKeyPath<TypographySettings, String>
    ) -> some View {
        let options = FontOptions.options(families: families, stored: stored)
        let missing = options.first { $0.isMissing }
        return VStack(alignment: .leading, spacing: 4) {
            Picker(
                title,
                selection: Binding(
                    get: { stored },
                    set: { family in
                        var next = settings.snapshot.typography
                        next[keyPath: field] = family
                        settings.set(.typography, next)
                    })
            ) {
                ForEach(options) { option in
                    if option.id.isEmpty {
                        Text(option.label).tag(option.id)
                        Divider()
                    } else {
                        Text(option.label).tag(option.id)
                    }
                }
            }
            .accessibilityLabel(title)
            if let missing {
                Label {
                    Text("“\(missing.id)” is not installed. The editor uses its default font.")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(title): \(missing.id) is not installed. The editor uses its default font.")
            }
        }
    }

    private func row(_ field: TypographyField, typography: TypographySettings) -> some View {
        TypographySliderRow(field: field, stored: typography[keyPath: field.keyPath]) { number in
            var next = settings.snapshot.typography
            next[keyPath: field.keyPath] = number
            settings.set(.typography, next)
        }
    }
}

/// One slider. The value being dragged lives here, so the thumb follows the pointer whatever the stored
/// snapshots do meanwhile; the store is written at most every 100 ms and once more with the final value.
private struct TypographySliderRow: View {
    let field: TypographyField
    let stored: Double
    let write: (Double) -> Void

    @State private var dragged: Double?
    @State private var isEditing = false
    @State private var coalescer = WriteCoalescer()

    var body: some View {
        let value = dragged ?? stored
        LabeledContent(field.title) {
            HStack {
                Slider(
                    value: Binding(
                        get: { dragged ?? stored },
                        set: { number in
                            let snapped = field.snapped(number)
                            guard snapped != (dragged ?? stored) else { return }
                            dragged = snapped
                            coalescer.update(snapped) { number in
                                write(number)
                                // A step without a drag (VoiceOver, arrow keys) has nothing to wait for.
                                if !isEditing { dragged = nil }
                            }
                        }),
                    in: field.range, step: field.step,
                    onEditingChanged: { editing in
                        isEditing = editing
                        guard !editing, let final = dragged else { return }
                        coalescer.finish(final, write: write)
                        dragged = nil
                    }
                )
                .labelsHidden()
                .accessibilityLabel(field.title)
                .accessibilityValue(field.format(value))
                Text(field.format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}
