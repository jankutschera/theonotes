// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import SwiftUI
import TheoNotesCore

/// Window ids of the About window and the Acknowledgements window it opens.
enum AboutWindow {
    static let about = "about"
    static let acknowledgements = "acknowledgements"
}

/// The facts the About window shows, read from the bundle.
struct AboutInfo: Equatable {
    var name: String
    var version: String
    var build: String
    var copyright: String

    static let fallbackName = "Theo Notes"

    init(name: String, version: String, build: String, copyright: String) {
        self.name = name
        self.version = version
        self.build = build
        self.copyright = copyright
    }

    init(bundle: Bundle = .main) {
        func string(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let display = string("CFBundleDisplayName")
        self.init(
            name: display.isEmpty ? Self.fallbackName : display,
            version: string("CFBundleShortVersionString"),
            build: string("CFBundleVersion"),
            copyright: string("NSHumanReadableCopyright"))
    }

    /// "Version 0.1.0 (1)"; the build number is left out when it equals the version or is missing.
    var versionLine: String {
        guard !version.isEmpty else { return build.isEmpty ? "" : "Build \(build)" }
        return build.isEmpty || build == version ? "Version \(version)" : "Version \(version) (\(build))"
    }

    var menuTitle: String { "About \(name)" }

    /// GPL source offer (L5); the URL is a clickable link.
    static var sourceOffer: AttributedString {
        var text = AttributedString(ProjectLinks.sourceOffer)
        if let range = text.range(of: ProjectLinks.sourceRepository.absoluteString) {
            text[range].link = ProjectLinks.sourceRepository
        }
        return text
    }
}

/// Theo Notes ▸ About Theo Notes: the name, version and copyright, and the way to the
/// Acknowledgements window.
struct AboutView: View {
    let info: AboutInfo
    @Environment(\.openWindow) private var openWindow

    init(info: AboutInfo = AboutInfo()) {
        self.info = info
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(info.name)
                .font(.title.bold())
            if !info.versionLine.isEmpty {
                Text(info.versionLine)
                    .foregroundStyle(.secondary)
            }
            if !info.copyright.isEmpty {
                Text(info.copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Theo Notes is built with open-source software. Each part keeps its own licence.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Button("Acknowledgements…") { openWindow(id: AboutWindow.acknowledgements) }
                .accessibilityIdentifier(AboutControl.acknowledgements)
                .padding(.top, 2)
            Text(AboutInfo.sourceOffer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier(AboutControl.sourceOffer)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 340)
    }
}

enum AboutControl {
    static let acknowledgements = "about.acknowledgements"
    static let sourceOffer = "about.source-offer"
}

/// Replaces the standard About item (which cannot hold a button) with the About window.
struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(AboutInfo().menuTitle) { openWindow(id: AboutWindow.about) }
        }
    }
}
