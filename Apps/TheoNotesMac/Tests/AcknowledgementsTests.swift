// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// LIC-R*: the Acknowledgements window and the About window that opens it. The list comes from
/// `Acknowledgements.json` in the app bundle (this is the host app's bundle in a hosted test run).
@MainActor
@Suite struct AcknowledgementsModelTests {
    private func bundled() -> AcknowledgementsModel { .bundled(.main) }

    @Test func theAppBundleShipsTheList() throws {
        let model = bundled()
        #expect(model.loadError == nil, "\(model.loadError ?? "")")
        #expect(model.totalCount > 50)
        #expect(model.selectedEntry != nil, "the first entry is selected when the window opens")
    }

    @Test func everyEntryHasLicenceText() throws {
        let model = bundled()
        let catalog = try #require(model.catalog)
        #expect(catalog.entriesWithoutLicenceText.isEmpty)
        for entry in model.visibleEntries {
            model.selectionID = entry.id
            #expect(model.selectedEntry == entry)
            #expect(model.licenceText.count > 200, "\(entry.name) shows no licence text")
            #expect(!model.licenceText.contains("missing from the app"), "\(entry.name)")
            #expect(!entry.copyright.isEmpty, "\(entry.name)")
        }
    }

    @Test func theShippedListNamesGRDBAndCodeMirrorButNotElkjs() throws {
        let model = bundled()
        model.query = "grdb"
        #expect(model.visibleEntries.map(\.name) == ["GRDB.swift"])
        model.query = "codemirror"
        #expect(model.visibleEntries.contains { $0.name == "@codemirror/view" && $0.licence == "MIT" })
        // Elkjs (EPL-2.0) is not part of the app.
        model.query = "elkjs"
        #expect(model.visibleEntries.isEmpty)
    }

    @Test func searchNarrowsTheListAndKeepsASelection() {
        let model = bundled()
        let total = model.totalCount
        #expect(model.countText == "\(total) components")
        model.query = "zzz-no-such-component"
        #expect(model.visibleEntries.isEmpty)
        #expect(model.selectedEntry == nil)
        #expect(model.licenceText.isEmpty)
        #expect(model.countText == "0 of \(total) components")
        model.query = ""
        #expect(model.visibleEntries.count == total)
        #expect(model.selectedEntry != nil)
    }

    @Test func aSelectionTheSearchHidesMovesToTheFirstMatch() throws {
        let model = bundled()
        model.query = "grdb"
        let grdb = try #require(model.selectedEntry)
        model.query = "codemirror"
        #expect(model.selectedEntry?.name.hasPrefix("@codemirror/") == true)
        #expect(model.selectedEntry != grdb)
    }

    @Test func aChoiceBetweenLicencesIsExplained() throws {
        let model = bundled()
        model.query = "dompurify"
        let entry = try #require(model.visibleEntries.first)
        #expect(entry.licence == "Apache-2.0")
        #expect(model.licenceLine(for: entry) == "Apache-2.0 (chosen from (MPL-2.0 OR Apache-2.0))")
        model.query = "grdb"
        #expect(model.licenceLine(for: try #require(model.visibleEntries.first)) == "MIT")
    }

    @Test func onlyWebAddressesBecomeLinks() throws {
        let model = bundled()
        let entry = try #require(model.visibleEntries.first)
        #expect(model.sourceURL(for: entry)?.scheme == "https")
        let odd = try #require(
            try? AcknowledgementsCatalog(
                jsonData: Data(
                    """
                    {"schemaVersion": 1, "texts": {"a": "x"}, "entries": [
                     {"name": "p", "version": "", "kind": "asset", "licence": "MIT", "copyright": "c", "textId": "a", "source": "javascript:alert(1)", "usedIn": ""}]}
                    """.utf8)))
        let oddModel = AcknowledgementsModel(catalog: odd)
        #expect(oddModel.sourceURL(for: odd.entries[0]) == nil)
        #expect(oddModel.sourceCodeURL(for: odd.entries[0]) == nil)
    }

    @Test func aBundleWithoutTheFileSaysSoInsteadOfShowingNothing() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("ack-empty-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let model = AcknowledgementsModel.bundled(try #require(Bundle(url: empty)))
        #expect(model.catalog == nil)
        #expect(model.loadError?.contains("could not be loaded") == true)
        #expect(model.visibleEntries.isEmpty)
    }
}

@MainActor
@Suite struct AboutInfoTests {
    @Test func versionLineShowsBuildOnlyWhenItAddsSomething() {
        func line(_ version: String, _ build: String) -> String {
            AboutInfo(name: "N", version: version, build: build, copyright: "").versionLine
        }
        #expect(line("0.1.0", "1") == "Version 0.1.0 (1)")
        #expect(line("0.1.0", "0.1.0") == "Version 0.1.0")
        #expect(line("0.1.0", "") == "Version 0.1.0")
        #expect(line("", "7") == "Build 7")
        #expect(line("", "") == "")
    }

    @Test func theSourceOfferLinksThePublicRepository() throws {
        let offer = AboutInfo.sourceOffer
        #expect(String(offer.characters) == ProjectLinks.sourceOffer)
        let link = try #require(offer.runs.compactMap(\.link).first)
        #expect(link == ProjectLinks.sourceRepository)
    }

    @Test func theMenuItemUsesTheProductName() {
        #expect(AboutInfo(name: "Theo Notes", version: "", build: "", copyright: "").menuTitle == "About Theo Notes")
    }

    /// "Theo Notes" in production, "Theo Notes Dev" in the dev build.
    @Test func theBundleSaysTheoNotes() {
        let info = AboutInfo(bundle: .main)
        #expect(info.name == AppIdentity.current.displayName)
        #expect(info.name.hasPrefix("Theo Notes"))
        #expect(!info.versionLine.isEmpty)
        #expect(info.copyright.contains("True Brew Birdie"))
    }
}

/// What a person can see: the About window offers "Acknowledgements…", the Acknowledgements window
/// lists the components. A hosted window exposes its SwiftUI accessibility tree only on an unlocked
/// screen, so this runs with `BAERCHEN_AX_AUDIT=1` there and is NOT VERIFIED (GUI) otherwise.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BAERCHEN_AX_AUDIT"] == "1"))
struct AcknowledgementsWindowTests {
    private func shown(_ view: some View, title: String) async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.contentViewController = NSHostingController(rootView: view)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        return window
    }

    @Test func theAboutWindowOffersTheAcknowledgements() async throws {
        let window = try await shown(AboutView(), title: "About Theo Notes")
        defer { window.close() }
        let labels = AccessibilityWalker.labels(in: window)
        #expect(labels.contains("Acknowledgements…"), "\(labels)")
        #expect(labels.contains("Theo Notes"), "\(labels)")
    }

    @Test func theWindowListsComponentsAndTheLicenceText() async throws {
        let window = try await shown(AcknowledgementsView(), title: "Acknowledgements")
        defer { window.close() }
        let labels = AccessibilityWalker.labels(in: window).joined(separator: "\n")
        #expect(labels.contains("components"), "\(labels)")
        #expect(labels.contains("MIT"), "\(labels)")
        #expect(AccessibilityAudit.issues(in: window).isEmpty, "\(AccessibilityAudit.issues(in: window))")
    }
}
