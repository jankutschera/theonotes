// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import CoreText
import Observation
import os

let appearanceControllerLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "appearance")

/// What the system says about the look of the Mac: injectable so tests flip it without touching the
/// real system settings.
@MainActor
protocol SystemAppearanceSource: AnyObject {
    var isDark: Bool { get }
    var increaseContrast: Bool { get }
    var reduceTransparency: Bool { get }
    var reduceMotion: Bool { get }
    /// `onChange` runs after any of the four values may have changed (it is not told which).
    func observe(_ onChange: @escaping @MainActor () -> Void)
}

/// The real system: the app's effective appearance and the Accessibility display options.
@MainActor
final class LiveSystemAppearance: SystemAppearanceSource {
    private var appearanceObservation: NSKeyValueObservation?
    private var accessibilityObserver: (any NSObjectProtocol)?

    var isDark: Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func observe(_ onChange: @escaping @MainActor () -> Void) {
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: []) { _, _ in
            Task { @MainActor in onChange() }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    isolated deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
}

/// A source that never changes: light, no accessibility options. The default of `AppEnvironment`, so a test
/// that builds one does not depend on the machine it runs on; the app passes `LiveSystemAppearance`.
@MainActor
final class StaticSystemAppearance: SystemAppearanceSource {
    var isDark = false
    var increaseContrast = false
    var reduceTransparency = false
    var reduceMotion = false
    func observe(_ onChange: @escaping @MainActor () -> Void) {}
}

/// The theme and the accessibility options as they apply now.
struct ResolvedAppearance: Equatable {
    var theme: Theme
    var reduceMotion: Bool
    var reduceTransparency: Bool
    var increaseContrast: Bool
}

/// What every editor shows: the bridge's `setEditorLook` arguments plus the colour behind the page.
struct EditorLook: Equatable {
    var typography: EditorTypography
    /// `[:]` for Theo Notes Red: the editor's own default theme, so nothing is sent for it.
    var theme: [String: String]
    var appearance: EditorAppearance
    var reduceMotion: Bool
    /// The theme's page background, for the web view's under-page colour (overscroll, before the page paints).
    var background: ThemeColor
    /// The same colour as the theme file spells it (`#rrggbb[aa]`), for the boot script.
    var backgroundHex: String
}

/// Resolves the look (stored mode and themes, the system, Increase Contrast, typography) and tells
/// every editor when it changes. The shell reads `resolved`; editors get `onLookChange`.
@MainActor
@Observable
final class AppearanceController {
    private(set) var resolved: ResolvedAppearance
    private(set) var editorLook: EditorLook
    private(set) var mode: AppearanceMode

    /// Runs after the editor look changed (not for a change the editors would not see).
    @ObservationIgnored var onLookChange: ((EditorLook) -> Void)?
    /// Settings snapshots handled so far.
    @ObservationIgnored private(set) var settingsSnapshotsSeen = 0
    /// The stored settings as last handled.
    @ObservationIgnored private(set) var snapshot: TheoNotesCore.Settings.Snapshot

    @ObservationIgnored private let system: any SystemAppearanceSource
    @ObservationIgnored private let installedFamilies: @MainActor () -> Set<String>
    @ObservationIgnored private let applyToApp: @MainActor (NSAppearance?) -> Void
    @ObservationIgnored private var observation: Task<Void, Never>?
    /// The installed font families, read when a font is first needed and again after the typography or the
    /// installed fonts change (the call is slow, and a system flip must not pay for it).
    @ObservationIgnored private var familiesCache: Set<String>?
    @ObservationIgnored private var fontsObserver: InstalledFontsObserver?

    /// `installedFamilies` is read when a font is needed and cached until the typography or the installed fonts
    /// change. `applyToApp` sets the app-wide appearance (`NSApp.appearance`); tests pass a recorder.
    init(
        settings: TheoNotesCore.Settings, system: any SystemAppearanceSource,
        installedFamilies: @escaping @MainActor () -> Set<String> = { Set(NSFontManager.shared.availableFontFamilies) },
        applyToApp: @escaping @MainActor (NSAppearance?) -> Void = AppearanceController.setAppAppearance
    ) {
        self.system = system
        self.installedFamilies = installedFamilies
        self.applyToApp = applyToApp
        let initial = (try? settings.snapshot()) ?? TheoNotesCore.Settings.Snapshot()
        snapshot = initial
        mode = initial.appearanceMode
        let initialFamilies: Set<String> = initial.typography.choosesFonts ? installedFamilies() : []
        if initial.typography.choosesFonts { familiesCache = initialFamilies }
        let state = Self.compute(snapshot: initial, system: system, families: { initialFamilies })
        resolved = state.resolved
        editorLook = state.look
        applyToApp(Self.nsAppearance(for: initial.appearanceMode))
        system.observe { [weak self] in self?.recompute() }
        observeInstalledFonts()
        observation = Task { [weak self] in
            do {
                for try await next in settings.observe() {
                    self?.settingsChanged(next)
                    self?.settingsSnapshotsSeen += 1
                }
            } catch {
                appearanceControllerLogger.error("settings observation failed: \(error)")
            }
        }
    }

    isolated deinit {
        observation?.cancel()
    }

    /// The real app's setter, the default of this controller; `AppEnvironment` defaults to a no-op instead.
    static func setAppAppearance(_ appearance: NSAppearance?) {
        NSApplication.shared.appearance = appearance
    }

    private func settingsChanged(_ next: TheoNotesCore.Settings.Snapshot) {
        guard next != snapshot else { return }
        let modeChanged = next.appearanceMode != snapshot.appearanceMode
        // Only a changed family name can need another font list (a size or width drag must not re-read it).
        let old = snapshot.typography
        let new = next.typography
        if old.fontText != new.fontText || old.fontHeading != new.fontHeading || old.fontCode != new.fontCode {
            familiesCache = nil
        }
        snapshot = next
        guard modeChanged else { return recompute() }
        mode = next.appearanceMode
        applyToApp(Self.nsAppearance(for: next.appearanceMode))
        if next.appearanceMode == .system {
            // The choice goes back to macOS: `effectiveAppearance` may still report the forced look in this
            // turn, so the system-dependent look is read one main-loop turn later (the KVO callback follows too).
            Task { @MainActor [weak self] in self?.recompute() }
        } else {
            recompute()
        }
    }

    /// The font set changed (a font was installed or removed): a chosen family may now resolve or not.
    func installedFontsChanged() {
        familiesCache = nil
        // The Typography pickers' lists too, also while that pane is not on screen to notice (final review M3).
        FontFamilies.invalidateCache()
        guard snapshot.typography.choosesFonts else { return }
        recompute()
    }

    private func observeInstalledFonts() {
        fontsObserver = InstalledFontsObserver { [weak self] in self?.installedFontsChanged() }
    }

    private func families() -> Set<String> {
        if let familiesCache { return familiesCache }
        let read = installedFamilies()
        familiesCache = read
        return read
    }

    private func recompute() {
        let state = Self.compute(snapshot: snapshot, system: system, families: { [self] in families() })
        if state.resolved != resolved { resolved = state.resolved }
        guard state.look != editorLook else { return }
        editorLook = state.look
        onLookChange?(state.look)
    }

    /// `.light` is Aqua, `.dark` is Dark Aqua, `.system` leaves the choice to macOS (nil).
    static func nsAppearance(for mode: AppearanceMode) -> NSAppearance? {
        switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private static func compute(
        snapshot: TheoNotesCore.Settings.Snapshot, system: any SystemAppearanceSource,
        families: @MainActor () -> Set<String>
    ) -> (resolved: ResolvedAppearance, look: EditorLook) {
        let theme = ThemeResolver.resolve(
            mode: snapshot.appearanceMode, systemIsDark: system.isDark, increaseContrast: system.increaseContrast,
            lightThemeId: snapshot.lightTheme, darkThemeId: snapshot.darkTheme)
        let resolved = ResolvedAppearance(
            theme: theme, reduceMotion: system.reduceMotion, reduceTransparency: system.reduceTransparency,
            increaseContrast: system.increaseContrast)
        var installed: Set<String> = []
        let chosen = snapshot.typography
        if chosen.choosesFonts {
            installed = families()
            for (field, name) in [("text", chosen.fontText), ("heading", chosen.fontHeading), ("code", chosen.fontCode)]
            where !name.isEmpty && !installed.contains(name) {
                // The name stays out of the log (it is user text); the field and its length find the setting.
                appearanceControllerLogger.notice(
                    "font family for \(field, privacy: .public) is not installed (\(name.count) characters), using the default")
            }
        }
        let backgroundHex = theme.editor["color-bg"].flatMap { ThemeColor(hex: $0) != nil ? $0 : nil } ?? "#ffffff"
        let look = EditorLook(
            typography: chosen.editorTypography(installedFamilies: installed),
            theme: theme.id == ThemeCatalog.defaultLightId ? [:] : theme.editorVariables,
            appearance: theme.appearance == .dark ? .dark : .light,
            reduceMotion: system.reduceMotion,
            background: ThemeColor(hex: backgroundHex) ?? ThemeColor(red: 1, green: 1, blue: 1),
            backgroundHex: backgroundHex)
        return (resolved, look)
    }
}

/// Calls `onChange` when the set of installed fonts may have changed: `NSFontSetChangedNotification` and
/// `kCTFontManagerRegisteredFontsChangedNotification` (local and distributed). The one list of those events,
/// shared by `AppearanceController` and the Typography pane.
@MainActor
final class InstalledFontsObserver {
    static let events: [(center: NotificationCenter, name: Notification.Name)] = {
        let registered = Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String)
        return [
            (.default, Notification.Name("NSFontSetChangedNotification")),
            (.default, registered),
            (DistributedNotificationCenter.default(), registered),
        ]
    }()

    private var tokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    init(onChange: @escaping @MainActor () -> Void) {
        for (center, name) in Self.events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            }
            tokens.append((center, token))
        }
    }

    isolated deinit {
        for observer in tokens { observer.center.removeObserver(observer.token) }
    }
}

extension NSColor {
    convenience init(_ color: ThemeColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
