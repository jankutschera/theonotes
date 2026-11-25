// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import GRDB
import PDFKit
import Testing
@testable import TheoNotes

/// Spec section 9 / FOC-R5 (C18): a note with a reminder, a hide and a history entry exports as HTML
/// and PDF with none of that state. The Core formats are covered in `FocusAcceptanceTests`. R34: the
/// renderer uses a hidden `WKWebView`; check the screen lock before reading a failure
/// (`ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked`).
@MainActor
@Suite(.serialized) final class FocusExportMacTests {
    let root: URL
    let environment: AppEnvironment
    let out: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesFocusExport-\(UUID().uuidString)")
        environment = try AppEnvironment(paths: AppPaths(root: root))
        out = root.appendingPathComponent("out", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Seeded {
        let note: Note
        let pingId: String
        let anchorHash: String
        let snapshotCanary: String
        /// Spellings of the reminder time a leak could take.
        let timeSpellings: [String]
    }

    /// A note holding every kind of focus state: a captured mark, an opened time, a line reminder,
    /// a hide on its to-do and a history entry whose words appear nowhere in the note.
    private func seed() throws -> Seeded {
        let store = environment.store
        let note = try store.create(text: "Export Me\n\n- [ ] ship the parcel\n\nplain words here\n", captureSource: .voice)
        let anchor = try #require(LineAnchor.at(line: 3, in: note.text))
        let fireAt = Date(timeIntervalSince1970: 1_950_000_000.5)
        let ping = try store.setPing(noteId: note.id, anchor: anchor, fireAt: fireAt)
        try store.recordOpened(noteId: note.id)
        let card = FocusCard(store: store)
        let todo = TodoCandidate(
            noteId: note.id, title: "Export Me", anchor: anchor, lineText: "ship the parcel",
            caretOffset: LineAnchor.utf16Offset(ofLine: 3, in: note.text) ?? 0, isReadOnly: false)
        try card.later(.todo(todo), now: .now)
        let canary = "history-canary-9d2e41"
        _ = try store.takeSnapshot(noteId: note.id, text: "Export Me\n\n\(canary)\n", now: .now)

        // The state is really there (so an empty result proves something).
        try environment.database.pool.read { db throws -> Void in
            for table in ["note_ping", "focus_hide", "note_snapshot"] {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE noteId = ?", arguments: [note.id]) ?? 0 > 0, Comment(rawValue: table))
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainISO = ISO8601DateFormatter()
        let seconds = Int64(ping.fireAt.timeIntervalSince1970)
        return Seeded(
            note: note, pingId: ping.id, anchorHash: anchor.hash, snapshotCanary: canary,
            timeSpellings: [iso.string(from: ping.fireAt), plainISO.string(from: ping.fireAt), String(seconds),
                            String(Int64(ping.fireAt.timeIntervalSince1970 * 1000)), "2031-10-"])
    }

    private func export(_ note: Note, _ settings: ExportSettings) async throws -> URL {
        let plan = ExportPlan.selection(try environment.store.exportCandidates(ids: [note.id]))
        let job = ExportJob(environment: environment, renderer: NoteRenderer(environment: environment))
        let report = await job.run(plan, settings: settings, destination: out, progress: { _, _ in }, isCancelled: { false })
        #expect(report.errors == [])
        #expect(report.exported == 1)
        return out.appendingPathComponent("Export Me." + settings.format.fileExtension)
    }

    private func expectClean(_ text: String, _ seeded: Seeded, label: String) {
        let needles = [seeded.snapshotCanary, seeded.pingId, seeded.anchorHash, "captureSource", "lastOpenedAt",
                       "hiddenUntil", "fireAt", "focus_hide", "note_ping"] + seeded.timeSpellings
        for needle in needles { #expect(!text.contains(needle), "\(needle) in \(label)") }
    }

    @Test func htmlAndPdfExportCarryNoFocusState() async throws {
        let seeded = try seed()

        // HTML through the export job (the renderer builds the page).
        let htmlFile = try await export(seeded.note, ExportSettings(format: .html, keepTags: true))
        let html = try String(contentsOf: htmlFile, encoding: .utf8)
        #expect(html.contains("ship the parcel") && html.contains("plain words here"))
        expectClean(html, seeded, label: "html")

        // PDF through the export job.
        let pdfFile = try await export(seeded.note, ExportSettings(format: .pdf, keepTags: true))
        let document = try #require(PDFDocument(url: pdfFile))
        #expect(document.pageCount >= 1)
        let pdfText = document.string ?? ""
        #expect(pdfText.contains("plain words here"))
        expectClean(pdfText, seeded, label: "pdf text")
        // The file's own bytes (metadata, outline, annotations) carry none of it either.
        expectClean(String(decoding: try Data(contentsOf: pdfFile), as: UTF8.self), seeded, label: "pdf bytes")

        // PDF straight through the renderer, the way printing builds it.
        let builder = RenderRequestBuilder(store: environment.store, paths: environment.paths)
        let look = environment.appearance.exportLook(themeId: nil)
        let request = try builder.request(
            for: seeded.note, mode: .document, theme: look.theme, appearance: look.appearance, typography: look.typography,
            attachments: .assetURLs, wikiLinks: .sameNote, keepTags: true)
        let direct = root.appendingPathComponent("direct-\(UUID().uuidString).pdf")
        _ = try await NoteRenderer(environment: environment).writePDF(request, to: direct)
        let directDocument = try #require(PDFDocument(url: direct))
        #expect((directDocument.string ?? "").contains("plain words here"))
        expectClean(directDocument.string ?? "", seeded, label: "direct pdf text")
        expectClean(String(decoding: try Data(contentsOf: direct), as: UTF8.self), seeded, label: "direct pdf bytes")
    }

    @Test func richTextExportCarriesNoFocusState() async throws {
        let seeded = try seed()
        let file = try await export(seeded.note, ExportSettings(format: .rtf, keepTags: true))
        let rtf = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(rtf.contains("plain words here"))
        expectClean(rtf, seeded, label: "rtf")
    }
}

/// The copy of the names table (plan, Global Constraints) as the Mac app really carries it, read from
/// the live constants and the built Info.plist rather than from the plan. The cross-surface check of
/// docs/focus-layer-parity.md; the per-feature copy tests stay next to their features.
@MainActor
@Suite struct FocusCopyReadTests {
    @Test func everyMacSurfaceReadsLikeTheNamesTable() throws {
        // A1
        #expect(CaptureThoughtMenu.title == "Capture Thought")
        #expect(NoteRow.capturedSymbol == "tray.and.arrow.down" && NoteRow.capturedLabel == "Captured")
        // A2
        #expect(VoiceMenu.captureTitle == "Capture Voice Note")
        #expect(VoiceMenu.insertTitle == "Insert Voice Note")
        #expect(VoiceMenu.panelTitle == "Voice Note")
        #expect(VoiceCaptureModel.modelQuestion(for: Locale(identifier: "en_US"))
            == "Voice notes need the speech model for English (United States). Download it from Apple now?")
        #expect(VoiceCaptureModel.stopNotice == "Recording stopped because the microphone changed.")
        // A3
        #expect(NextUpMenu.title == "Next Up")
        #expect(NextUpModel.timerNotificationTitle == "Time's up")
        // A4
        #expect(RemindMeMenu.title == "Remind Me…")
        #expect(EditorContextMenu.remindTitle == "Remind Me…")
        #expect(ReminderSheetModel.confirmTitle == "Remind Me")
        #expect(MacNotificationCategory.snoozeHourTitle == "In 1 Hour")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        #expect(MacNotificationCategory.snoozeNineTitle(locale: Locale(identifier: "de_DE"), calendar: calendar) == "At 09:00")
        // A5
        #expect(NoteHistoryModel.title == "Note History")
        #expect(NoteHistoryModel.restoreTitle == "Restore as Copy")
        #expect(NoteHistoryModel.replaceTitle == "Replace This Note…")
        #expect(NoteHistoryModel.replaceQuestion == "Replace the note with this version? The current text is kept in the history.")
        #expect(NoteHistoryModel.replaceConfirmTitle == "Replace" && NoteHistoryModel.cancelTitle == "Cancel")
        // While App Lock is enabled
        #expect(PingPlanner.genericTitle == "Theo Notes" && PingPlanner.genericBody == "Reminder")
        // Usage string: the microphone only, no speech-recognition string (FOC-R9).
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["NSMicrophoneUsageDescription"] as? String
            == "Theo Notes records your voice note and keeps the recording with the note.")
        #expect(info["NSSpeechRecognitionUsageDescription"] == nil)
    }
}
