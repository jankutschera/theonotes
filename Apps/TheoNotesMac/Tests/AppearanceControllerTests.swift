// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
import WebKit
@testable import TheoNotes

@MainActor
final class FakeSystemAppearance: SystemAppearanceSource {
    var isDark: Bool {
        get { staleDark ?? actualDark }
        set { actualDark = newValue }
    }
    private var actualDark = false
    /// While set, reads report this instead (AppKit's `effectiveAppearance` right after `NSApp.appearance = nil`).
    var staleDark: Bool?
    var increaseContrast = false
    var reduceTransparency = false
    var reduceMotion = false
    private var handlers: [@MainActor () -> Void] = []

    func observe(_ onChange: @escaping @MainActor () -> Void) { handlers.append(onChange) }
    /// What the system does after a setting changed.
    func fire() { handlers.forEach { $0() } }
}

/// M7 Task 7: the resolved look reaches every open editor in place, and a new editor starts with it.
@MainActor
@Suite struct AppearanceControllerTests {
    final class Applied { var names: [NSAppearance.Name?] = [] }
    /// The environment holds editors weakly, so the test keeps them alive.
    final class Editors { var all: [EditorBridgeController] = [] }
    final class Counter { var reads = 0 }

    let system = FakeSystemAppearance()
    let applied = Applied()
    let editors = Editors()
    let familyReads = Counter()
    let environment: AppEnvironment
    let settings: TheoNotesCore.Settings
    let noteId: String

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesMacTests-\(UUID().uuidString)")
        let applied = applied
        let familyReads = familyReads
        let system = system
        environment = try AppEnvironment(
            paths: AppPaths(root: root), systemAppearance: system,
            installedFontFamilies: {
                familyReads.reads += 1
                return ["Georgia", "Menlo"]
            },
            applyAppAppearance: {
                applied.names.append($0?.name)
                if $0 == nil, system.isDark {
                    // Handing the choice back to macOS: AppKit still reports the forced look for this turn.
                    system.staleDark = false
                    Task { @MainActor in system.staleDark = nil }
                }
            })
        settings = TheoNotesCore.Settings(db: environment.database)
        noteId = try environment.store.create(text: "hello").id
    }

    private func makeEditor() throws -> (EditorBridgeController, FakeEditorPage) {
        let page = FakeEditorPage()
        let controller = EditorBridgeController(
            environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
        editors.all.append(controller)
        return (controller, page)
    }

    private func settingsMessages(_ page: FakeEditorPage) -> [EditorSettings] {
        page.delivered.compactMap { if case .setSettings(let s) = $0 { s } else { nil } }
    }

    private func theme(_ id: String) throws -> Theme { try #require(ThemeCatalog.theme(id: id)) }

    /// Waits for the controller to have handled the stored settings the test wrote (by value, not by count).
    private func settled(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        try await waitUntil(what) { condition() }
    }

    @Test func systemFlipResendsThemeToEveryEditor() async throws {
        let (_, first) = try makeEditor()
        let (_, second) = try makeEditor()
        #expect(settingsMessages(first).isEmpty && settingsMessages(second).isEmpty, "Theo Notes Red is the page default")
        system.isDark = true
        system.fire()
        let dark = try theme("baerchen-dark")
        for page in [first, second] {
            let sent = try #require(settingsMessages(page).last)
            #expect(sent.theme == dark.editorVariables)
            #expect(sent.appearance == .dark)
            #expect(page.loadNotes.count == 1, "no reload")
        }
        // And back: the default theme is `[:]`, which clears the tokens.
        system.isDark = false
        system.fire()
        for page in [first, second] {
            #expect(settingsMessages(page).last == EditorSettings(theme: [:], appearance: .light))
        }
    }

    @Test func increaseContrastSendsHighContrast() async throws {
        let (_, page) = try makeEditor()
        system.increaseContrast = true
        system.fire()
        #expect(environment.appearance.resolved.increaseContrast)
        #expect(environment.appearance.resolved.theme.id == "high-contrast")
        let sent = try #require(settingsMessages(page).last)
        #expect(sent.theme == (try theme("high-contrast")).editorVariables)
        #expect(sent.appearance == nil, "still light, which is the page's")
        // Dark and Increase Contrast: OLED Black.
        system.isDark = true
        system.fire()
        #expect(environment.appearance.resolved.theme.id == "oled-black")
        #expect(settingsMessages(page).last?.appearance == .dark)
    }

    @Test func modeLightSetsAquaAndIgnoresSystemDark() async throws {
        let (_, page) = try makeEditor()
        #expect(applied.names == [nil], "System mode leaves the app appearance to macOS")
        settings.appearanceMode = .light
        try await settled("mode light") { environment.appearance.mode == .light }
        #expect(applied.names.last == .aqua)
        system.isDark = true
        system.fire()
        #expect(environment.appearance.resolved.theme.id == "baerchen-red")
        #expect(settingsMessages(page).isEmpty, "a forced light mode ignores the system's dark")

        settings.appearanceMode = .dark
        try await settled("mode dark") { environment.appearance.mode == .dark }
        #expect(applied.names.last == .darkAqua)
        #expect(settingsMessages(page).last?.appearance == .dark)

        settings.appearanceMode = .system
        try await settled("mode system") { environment.appearance.mode == .system }
        #expect(applied.names.last == .some(nil))
    }

    /// Back to System with a dark system: AppKit may still report the forced look in the turn of the switch.
    @Test func returningToSystemPicksUpADarkSystem() async throws {
        let (_, page) = try makeEditor()
        system.isDark = true
        settings.appearanceMode = .light
        try await settled("mode light") { environment.appearance.mode == .light }
        #expect(environment.appearance.resolved.theme.id == "baerchen-red")
        #expect(settingsMessages(page).isEmpty)

        settings.appearanceMode = .system
        try await settled("dark theme after System") { environment.appearance.resolved.theme.id == "baerchen-dark" }
        #expect(settingsMessages(page).last?.appearance == .dark)
        #expect(settingsMessages(page).last?.theme == (try theme("baerchen-dark")).editorVariables)
    }

    @Test func baerchenRedSendsNoThemeTokens() async throws {
        // Something else differs from the defaults, so a `setSettings` goes out before the note.
        settings.hideMarkdown = false
        let (_, page) = try makeEditor()
        let sent = try #require(settingsMessages(page).first)
        #expect(sent.hideMarkdown == false)
        #expect(sent.theme == nil)
        #expect(sent.appearance == nil)
        #expect(sent.typography == nil)
        #expect(sent.reduceMotion == nil)
    }

    @Test func typographyChangeIsSentInPlace() async throws {
        let (_, page) = try makeEditor()
        var typography = TypographySettings.default
        typography.fontSize = 18
        typography.fontText = "Georgia"
        typography.fontCode = "Gone Mono"
        settings.typography = typography
        try await settled("typography stored") { environment.appearance.snapshot.typography == typography }
        let sent = try #require(settingsMessages(page).last)
        #expect(sent.typography == EditorTypography(fontSize: 18, fontText: "Georgia"), "a missing family is not sent")
        #expect(page.loadNotes.count == 1, "no reload")
        // Back to the defaults clears it.
        settings.typography = .default
        try await settled("typography reset") { environment.appearance.snapshot.typography == .default }
        #expect(settingsMessages(page).last == EditorSettings(typography: EditorTypography()))
    }

    @Test func reduceMotionFollowsTheSystem() async throws {
        let (_, page) = try makeEditor()
        system.reduceMotion = true
        system.fire()
        #expect(environment.appearance.resolved.reduceMotion)
        #expect(settingsMessages(page).last == EditorSettings(reduceMotion: true))
        system.reduceMotion = false
        system.fire()
        #expect(settingsMessages(page).last == EditorSettings(reduceMotion: false))
    }

    @Test func aNewEditorStartsWithTheCurrentLook() async throws {
        system.isDark = true
        system.reduceMotion = true
        system.fire()
        var typography = TypographySettings.default
        typography.lineWidth = 900
        settings.typography = typography
        try await settled("typography stored") { environment.appearance.snapshot.typography == typography }
        let (_, page) = try makeEditor()
        guard page.delivered.count >= 2, case .setSettings(let sent) = page.delivered[0], case .loadNote = page.delivered[1] else {
            Issue.record("expected setSettings then loadNote: \(page.delivered)")
            return
        }
        #expect(sent.theme == (try theme("baerchen-dark")).editorVariables)
        #expect(sent.appearance == .dark)
        #expect(sent.reduceMotion == true)
        #expect(sent.typography == EditorTypography(lineWidth: 900))
    }

    /// Carried from M7 Task 3: OLED Black's pure black reaches the editor background and the web view behind the page.
    @Test func oledBlackReachesTheEditorAndTheUnderPageBackground() async throws {
        settings.darkTheme = "oled-black"
        try await settled("dark theme stored") { environment.appearance.snapshot.darkTheme == "oled-black" }
        let (firstController, first) = try makeEditor()
        let (secondController, second) = try makeEditor()
        #expect(underPage(firstController) == [1, 1, 1, 1], "Theo Notes Red is white")
        system.isDark = true
        system.fire()
        for (controller, page) in [(firstController, first), (secondController, second)] {
            let sent = try #require(settingsMessages(page).last)
            #expect(sent.theme?["--bc-color-bg"] == "#000000")
            #expect(underPage(controller) == [0, 0, 0, 1])
        }
        // A forced light mode puts the white back.
        settings.appearanceMode = .light
        try await settled("mode light") { environment.appearance.mode == .light }
        #expect(underPage(firstController) == [1, 1, 1, 1])
        // A new editor in the dark starts black.
        settings.appearanceMode = .dark
        try await settled("mode dark") { environment.appearance.mode == .dark }
        let (thirdController, _) = try makeEditor()
        #expect(underPage(thirdController) == [0, 0, 0, 1])
    }

    @Test func anUnknownThemeFallsBackToTheoNotesRed() async throws {
        settings.lightTheme = "no-such-theme"
        try await settled("light theme stored") { environment.appearance.snapshot.lightTheme == "no-such-theme" }
        #expect(environment.appearance.resolved.theme.id == "baerchen-red")
        let (_, page) = try makeEditor()
        #expect(settingsMessages(page).isEmpty)
    }

    @Test func aClosedWindowIsForgottenAndTheOthersFollow() async throws {
        let (_, kept) = try makeEditor()
        let closedPage = FakeEditorPage()
        var closed: EditorBridgeController? = EditorBridgeController(
            environment: environment, page: closedPage, openExternally: { _ in }, checksumInterval: nil)
        try closed?.open(noteId: noteId)
        _ = closed?.handle(.ready(version: EditorBridge.version))
        closed = nil
        let sentBefore = closedPage.delivered.count
        system.isDark = true
        system.fire()
        settings.darkTheme = "dracula"
        try await settled("dark theme stored") { environment.appearance.snapshot.darkTheme == "dracula" }
        #expect(closedPage.delivered.count == sentBefore, "nothing reaches a closed window")
        #expect(settingsMessages(kept).last?.theme == (try theme("dracula")).editorVariables)
    }

    @Test func aThemeOfTheWrongAppearanceFallsBackToTheSlotDefault() async throws {
        let (_, page) = try makeEditor()
        // Dark slot, unknown id: Theo Notes Dark.
        system.isDark = true
        settings.darkTheme = "no-such-theme"
        try await settled("dark theme stored") { environment.appearance.snapshot.darkTheme == "no-such-theme" }
        system.fire()
        #expect(environment.appearance.resolved.theme.id == "baerchen-dark")
        #expect(settingsMessages(page).last?.theme == (try theme("baerchen-dark")).editorVariables)
        // Light slot holding a dark theme: Theo Notes Red.
        system.isDark = false
        settings.lightTheme = "dracula"
        try await settled("light theme stored") { environment.appearance.snapshot.lightTheme == "dracula" }
        system.fire()
        #expect(environment.appearance.resolved.theme.id == "baerchen-red")
        #expect(settingsMessages(page).last == EditorSettings(theme: [:], appearance: .light))
    }

    @Test func aChosenDarkThemeGivesWayToOLEDBlackUnderIncreaseContrast() async throws {
        settings.darkTheme = "dracula"
        settings.appearanceMode = .dark
        try await settled("settings stored") {
            environment.appearance.snapshot.darkTheme == "dracula" && environment.appearance.mode == .dark
        }
        #expect(environment.appearance.resolved.theme.id == "dracula")
        system.increaseContrast = true
        system.fire()
        #expect(environment.appearance.resolved.theme.id == "oled-black")
    }

    @Test func theFontListIsReadOnceAndAgainWhenFontsOrTypographyChange() async throws {
        #expect(familyReads.reads == 0, "default typography names no font")
        var typography = TypographySettings.default
        typography.fontText = "Georgia"
        settings.typography = typography
        try await settled("typography stored") { environment.appearance.snapshot.typography == typography }
        #expect(familyReads.reads == 1)
        for _ in 0..<3 {
            system.isDark.toggle()
            system.fire()
        }
        #expect(familyReads.reads == 1, "system flips do not read the installed fonts")
        environment.appearance.installedFontsChanged()
        #expect(familyReads.reads == 2)
        typography.fontCode = "Menlo"
        settings.typography = typography
        try await settled("typography stored") { environment.appearance.snapshot.typography == typography }
        #expect(familyReads.reads == 3)
    }

    /// M7 final review M3: the Typography pickers' font lists are cached and were only dropped by the pane's own
    /// observer, which lives while the pane is on screen. A font installed with Settings closed must not stay
    /// missing from the pickers, so the always-on `AppearanceController` drops the cache too.
    @Test func installedFontsChangedDropsThePickersFontLists() {
        _ = FontFamilies.lists()
        #expect(FontFamilies.isCached)
        environment.appearance.installedFontsChanged()
        #expect(!FontFamilies.isCached, "the next picker render reads the installed fonts again")
    }

    @Test func aSizeOrWidthDragDoesNotReadTheFontListAgain() async throws {
        var typography = TypographySettings.default
        typography.fontText = "Georgia"
        settings.typography = typography
        try await settled("font stored") { environment.appearance.snapshot.typography == typography }
        #expect(familyReads.reads == 1)
        for size in stride(from: 17.0, through: 30.0, by: 1.0) {
            typography.fontSize = size
            typography.lineWidth = 400 + size * 10
            settings.typography = typography
            try await settled("size \(size) stored") { environment.appearance.snapshot.typography == typography }
        }
        #expect(familyReads.reads == 1, "only a changed family name flushes the font list")
        #expect(environment.appearance.editorLook.typography.fontSize == 30)
        #expect(environment.appearance.editorLook.typography.fontText == "Georgia")
        typography.fontHeading = "Menlo"
        settings.typography = typography
        try await settled("heading font stored") { environment.appearance.snapshot.typography == typography }
        #expect(familyReads.reads == 2)
    }

    // MARK: - No white flash (the boot script)

    @Test func theBootScriptCarriesTheOLEDBackgroundAndOnlySanitizedValues() async throws {
        settings.darkTheme = "oled-black"
        system.isDark = true
        try await settled("dark theme stored") { environment.appearance.snapshot.darkTheme == "oled-black" }
        system.fire()
        var look = environment.appearance.editorLook
        #expect(look.backgroundHex == "#000000")
        // A stray variable, a non-hex value and a hostile background must not get into the script.
        look.theme["--bc-nonsense"] = "#ffffff"
        look.theme["--bc-color-link"] = "red; } body { display:none"
        let script = EditorBoot.bootScript(for: look)
        #expect(script.contains("\"#000000\""))
        #expect(script.contains("html .cm-editor{background-color:#000000}"))
        #expect(script.contains("\"dark\""))
        #expect(!script.contains("nonsense"))
        #expect(!script.contains("display:none"))
        let clean = ThemeSchema.sanitize(variables: look.theme)
        #expect(clean.count == look.theme.count - 2)
        for key in clean.keys { #expect(script.contains("\"\(key)\"")) }
        #expect(!script.contains("--bc-color-link"), "the invalid link value drops its variable")

        var hostile = look
        hostile.backgroundHex = "red;}</style><script>"
        #expect(!EditorBoot.bootScript(for: hostile).contains("<script>"))
        #expect(EditorBoot.bootScript(for: hostile).contains("html .cm-editor{background-color:#ffffff}"))
    }

    @Test func everyWebViewCarriesTheBootScriptOfTheCurrentLook() async throws {
        let (first, firstPage) = try makeEditor()
        func sources(_ controller: EditorBridgeController) -> [String] {
            controller.webView.configuration.userContentController.userScripts.map(\.source)
        }
        #expect(sources(first).count == 1)
        #expect(sources(first)[0].contains("html .cm-editor{background-color:#ffffff}"))
        settings.darkTheme = "oled-black"
        system.isDark = true
        try await settled("dark theme stored") { environment.appearance.snapshot.darkTheme == "oled-black" }
        system.fire()
        #expect(sources(first).count == 1, "replaced, not stacked")
        #expect(sources(first)[0].contains("html .cm-editor{background-color:#000000}"))
        #expect(firstPage.settledLooks.last?.backgroundHex == "#000000", "the ready page is settled to the new look")
        // A window opened now (or a page reloaded after the web process ended) boots in the dark.
        let (second, secondPage) = try makeEditor()
        #expect(sources(second).count == 1)
        #expect(sources(second)[0].contains("html .cm-editor{background-color:#000000}"))
        #expect(secondPage.settledLooks.last?.backgroundHex == "#000000", "ready settles the page")
        // And back.
        system.isDark = false
        system.fire()
        #expect(sources(second)[0].contains("html .cm-editor{background-color:#ffffff}"))
    }

    /// The script in a real WebKit: the root and the editor element are painted at document start, and the
    /// settle script hands the editor back to its own styles.
    @Test func theBootScriptPaintsBeforeAnySettingsInRealWebKit() async throws {
        settings.darkTheme = "oled-black"
        system.isDark = true
        try await settled("dark theme stored") { environment.appearance.snapshot.darkTheme == "oled-black" }
        system.fire()
        let look = environment.appearance.editorLook

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: EditorBoot.bootScript(for: look), injectionTime: .atDocumentStart, forMainFrameOnly: true,
                in: .page))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let loader = NavigationWaiter()
        webView.navigationDelegate = loader
        let html = """
            <!doctype html><html><head><style>.cm-editor{background-color:#ffffff}</style></head>
            <body><div class='cm-editor'>x</div></body></html>
            """
        try await loader.load(html, in: webView)
        let probe = """
            JSON.stringify({
              root: getComputedStyle(document.documentElement).backgroundColor,
              scheme: document.documentElement.style.colorScheme,
              editor: getComputedStyle(document.querySelector('.cm-editor')).backgroundColor,
              boot: !!document.getElementById('bc-boot'),
              variable: document.documentElement.style.getPropertyValue('--bc-color-bg')
            })
            """
        func read() async throws -> [String: Any] {
            let text = try #require(try await webView.evaluateJavaScript(probe) as? String)
            return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let booted = try await read()
        #expect(booted["root"] as? String == "rgb(0, 0, 0)")
        #expect(booted["scheme"] as? String == "dark")
        #expect(booted["editor"] as? String == "rgb(0, 0, 0)")
        #expect(booted["boot"] as? Bool == true)
        #expect(booted["variable"] as? String == "#000000")

        // Settled to Theo Notes Red: the boot rule and the root variables are gone, the editor is its own again.
        let red = EditorLook(
            typography: EditorTypography(), theme: [:], appearance: .light, reduceMotion: false,
            background: ThemeColor(red: 1, green: 1, blue: 1), backgroundHex: "#ffffff")
        _ = try await webView.evaluateJavaScript(EditorBoot.settleScript(for: red))
        let settledLook = try await read()
        #expect(settledLook["root"] as? String == "rgb(255, 255, 255)")
        #expect(settledLook["scheme"] as? String == "light")
        #expect(settledLook["editor"] as? String == "rgb(255, 255, 255)")
        #expect(settledLook["boot"] as? Bool == false)
        #expect(settledLook["variable"] as? String == "")
    }

    private func underPage(_ controller: EditorBridgeController) -> [Double] {
        guard let color = controller.webView.underPageBackgroundColor.usingColorSpace(.sRGB) else { return [] }
        let components: [CGFloat] = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        return components.map { Double(($0 * 255).rounded() / 255) }
    }
}

/// Loads HTML into a web view and resumes when the navigation finished.
@MainActor
final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
