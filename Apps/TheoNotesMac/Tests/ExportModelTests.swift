// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// A job double: records what it was asked, reports `total` steps and, when gated, waits for
/// `open()` so a test can look at (or cancel) the running state.
@MainActor
final class FakeExportService: ExportService {
    var selectionPlan = ExportPlan.Result(items: [ExportItem(noteId: "a", folder: [], stem: "A")])
    var tagPlan = ExportPlan.Result(items: [ExportItem(noteId: "b", folder: ["work"], stem: "B")])
    var planError: (any Error)?
    var report: ((URL) -> ExportJobReport) = { ExportJobReport(exported: 1, destination: $0) }
    let gated: Bool

    private(set) var planned: [String] = []
    private(set) var runs: [(plan: ExportPlan.Result, settings: ExportSettings, destination: URL)] = []
    private(set) var sawCancelled = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false

    init(gated: Bool = false) { self.gated = gated }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }

    func plan(ids: [String]) throws -> ExportPlan.Result {
        planned.append("ids \(ids.joined(separator: ","))")
        if let planError { throw planError }
        return selectionPlan
    }

    func plan(tagTree: String) throws -> ExportPlan.Result {
        planned.append("tag \(tagTree)")
        if let planError { throw planError }
        return tagPlan
    }

    func run(
        _ plan: ExportPlan.Result, settings: ExportSettings, destination: URL,
        progress: (Int, Int) -> Void, isCancelled: () -> Bool
    ) async -> ExportJobReport {
        runs.append((plan, settings, destination))
        progress(0, plan.items.count)
        if gated, !opened { await withCheckedContinuation { waiting = $0 } }
        sawCancelled = isCancelled()
        if !sawCancelled { progress(plan.items.count, plan.items.count) }
        var result = report(destination)
        if sawCancelled { result.exported = 0 }
        return result
    }
}

@MainActor
@Suite(.serialized) struct ExportModelTests {
    let defaults: UserDefaults
    let destination = URL(fileURLWithPath: "/tmp/baerchen-export-model-test/out", isDirectory: true)

    init() {
        defaults = UserDefaults(suiteName: "ExportModelTests-\(UUID().uuidString)")!
    }

    /// The panel is a test seam: it records what it was shown and lets the test answer it.
    final class PanelProbe {
        var shown: [(title: String, settings: ExportSettings)] = []
        var answer: ((URL, ExportSettings) -> Void)?
        var cancel: (() -> Void)?
    }

    private func model(
        _ service: FakeExportService, probe: PanelProbe = PanelProbe(), keepTags: Bool = true
    ) -> ExportModel {
        ExportModel(
            service: service, defaults: defaults, keepTags: { keepTags },
            panel: { title, settings, completion, cancelled in
                probe.shown.append((title, settings))
                probe.answer = completion
                probe.cancel = cancelled
            })
    }

    private func settled(_ model: ExportModel) async {
        await model.runTask?.value
    }

    // MARK: - Which notes ⇧⌘S exports

    @Test func shiftCommandSExportsTheTagTreeWhenTheSidebarHasFocus() {
        let target = ExportTarget.resolve(
            scope: .tag("work/meetings"), noteListFocused: false, editorFocused: false, selection: ["a", "b"])
        #expect(target == .tagTree("work/meetings"))
        // No selection needed for a tag tree.
        #expect(ExportTarget.resolve(scope: .tag("work"), noteListFocused: false, editorFocused: false, selection: [])
            == .tagTree("work"))
    }

    @Test func shiftCommandSExportsTheSelectionOtherwise() {
        // The note list or the editor has focus: the selected notes, even inside a tag.
        #expect(ExportTarget.resolve(scope: .tag("work"), noteListFocused: true, editorFocused: false, selection: ["a"])
            == .selection(["a"]))
        #expect(ExportTarget.resolve(scope: .tag("work"), noteListFocused: false, editorFocused: true, selection: ["a", "b"])
            == .selection(["a", "b"]))
        // Not a tag scope: the selection.
        #expect(ExportTarget.resolve(scope: .notes, noteListFocused: false, editorFocused: false, selection: ["a"])
            == .selection(["a"]))
        // Nothing to export.
        #expect(ExportTarget.resolve(scope: .notes, noteListFocused: true, editorFocused: false, selection: []) == nil)
        #expect(ExportTarget.resolve(scope: .tag("work"), noteListFocused: true, editorFocused: false, selection: []) == nil)
    }

    // MARK: - Settings

    @Test func keepTagsFollowsTheSetting() async {
        for keep in [true, false] {
            let service = FakeExportService()
            let probe = PanelProbe()
            let model = model(service, probe: probe, keepTags: keep)
            model.exportSelection(["a"])
            #expect(probe.shown.first?.settings.keepTags == keep)
            // Whatever the panel hands back, keepTags comes from the setting.
            var answered = probe.shown[0].settings
            answered.keepTags = !keep
            probe.answer?(destination, answered)
            await settled(model)
            #expect(service.runs.first?.settings.keepTags == keep)
        }
    }

    @Test func settingsArePersistedPerFormat() async {
        let service = FakeExportService()
        let probe = PanelProbe()
        let first = model(service, probe: probe)
        #expect(first.lastSettings.format == .markdown)
        first.exportSelection(["a"])
        probe.answer?(destination, ExportSettings(
            format: .html, keepTags: true, htmlLinksBetweenNotes: true, htmlEmbedImages: true))
        await settled(first)
        // Then a PDF export with a theme: the HTML options are not forgotten.
        first.dismiss()
        first.exportSelection(["a"])
        // The panel opens with the remembered options; the user only switches format and theme.
        var again = probe.shown.last!.settings
        #expect(again.format == .html)
        #expect(again.htmlLinksBetweenNotes)
        again.format = .pdf
        again.pdfThemeId = "night"
        probe.answer?(destination, again)
        await settled(first)

        let second = model(FakeExportService(), probe: probe, keepTags: false)
        let remembered = second.lastSettings
        #expect(remembered.format == .pdf)
        #expect(remembered.pdfThemeId == "night")
        #expect(remembered.htmlLinksBetweenNotes)
        #expect(remembered.htmlEmbedImages)
        // keepTags is never stored: it is the setting's value.
        #expect(!remembered.keepTags)
        #expect(defaults.data(forKey: ExportModel.defaultsKey) != nil)
        #expect(ExportModel.defaultsKey == "Export.settings")
    }

    @Test func attachmentChoicesAreRememberedAndOlderStoredSettingsKeepTheDefaults() async {
        // Stored before 1.1: neither key is there.
        defaults.set(Data(#"{"format":"markdown","htmlLinksBetweenNotes":false,"htmlEmbedImages":false}"#.utf8), forKey: ExportModel.defaultsKey)
        let old = model(FakeExportService()).lastSettings
        #expect(old.includeAttachments)
        #expect(!old.markdownEmbedImages)

        let service = FakeExportService()
        let probe = PanelProbe()
        let first = model(service, probe: probe)
        first.exportSelection(["a"])
        probe.answer?(destination, ExportSettings(
            format: .markdown, keepTags: true, includeAttachments: false, markdownEmbedImages: true))
        await settled(first)
        let remembered = model(FakeExportService()).lastSettings
        #expect(!remembered.includeAttachments)
        #expect(remembered.markdownEmbedImages)
    }

    @Test func aDamagedStoredValueFallsBackToDefaults() {
        defaults.set(Data("not json".utf8), forKey: ExportModel.defaultsKey)
        let model = model(FakeExportService())
        #expect(model.lastSettings.format == .markdown)
        #expect(!model.lastSettings.htmlEmbedImages)
    }

    // MARK: - Running

    @Test func eachStartShowsThePanelFirst() async {
        let service = FakeExportService()
        let probe = PanelProbe()
        let model = model(service, probe: probe)
        model.exportSelection(["a", "b"])
        #expect(probe.shown.map(\.title) == ["Export 2 Notes"])
        #expect(service.runs.isEmpty)
        #expect(model.phase == .idle)
        probe.answer?(destination, probe.shown[0].settings)
        await settled(model)
        #expect(service.planned == ["ids a,b"])

        model.dismiss()
        model.exportTagTree("work")
        #expect(probe.shown.map(\.title) == ["Export 2 Notes", "Export #work"])
        probe.answer?(destination, probe.shown[1].settings)
        await settled(model)
        #expect(service.planned == ["ids a,b", "tag work"])
        #expect(service.runs.map(\.plan.items.count) == [1, 1])
    }

    @Test func cancellingThePanelStartsNothing() {
        let service = FakeExportService()
        let probe = PanelProbe()
        let model = model(service, probe: probe)
        model.exportSelection(["a"])
        #expect(model.isChoosing)
        // A second start while the panel is up is ignored.
        model.exportSelection(["a"])
        #expect(probe.shown.count == 1)
        probe.cancel?()
        #expect(!model.isChoosing)
        #expect(model.phase == .idle)
        #expect(service.runs.isEmpty)
    }

    @Test func runningDisablesTheCommands() async {
        let service = FakeExportService(gated: true)
        let probe = PanelProbe()
        let model = model(service, probe: probe)
        #expect(!model.isRunning)
        model.exportSelection(["a"])
        probe.answer?(destination, probe.shown[0].settings)
        await Task.yield()
        #expect(model.isRunning)
        #expect(model.phase == .running(done: 0, total: 1))
        // A second start while running shows no panel.
        model.exportSelection(["a"])
        #expect(probe.shown.count == 1)

        func enabled(importer: Bool = false, restore: Bool = false) -> Bool {
            ExportCommandAvailability.isEnabled(
                importRunning: importer, exportBusy: model.isRunning || model.isChoosing, restoreRunning: restore,
                hasTarget: true)
        }
        #expect(!enabled())
        service.open()
        await settled(model)
        #expect(!model.isRunning)
        #expect(enabled())
        #expect(!enabled(importer: true))
        #expect(!enabled(restore: true))
        #expect(!ExportCommandAvailability.isEnabled(
            importRunning: false, exportBusy: false, restoreRunning: false, hasTarget: false))
    }

    @Test func cancelTellsTheJobAndShowsNothingWasExported() async {
        let service = FakeExportService(gated: true)
        let probe = PanelProbe()
        let model = model(service, probe: probe)
        model.exportSelection(["a"])
        probe.answer?(destination, probe.shown[0].settings)
        await Task.yield()
        model.cancel()
        #expect(model.isCancelling)
        service.open()
        await settled(model)
        #expect(service.sawCancelled)
        guard case .finished(let report) = model.phase else { Issue.record("expected finished, got \(model.phase)"); return }
        #expect(report.exported == 0)
        #expect(model.wasCancelled)
        let summary = ExportReportSummary(report, wasCancelled: model.wasCancelled)
        #expect(summary.headline == "Export cancelled. Nothing was exported.")
    }

    @Test func aFailingPlanShowsTheError() async {
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        let service = FakeExportService()
        service.planError = Boom()
        let probe = PanelProbe()
        let model = model(service, probe: probe)
        model.exportSelection(["a"])
        probe.answer?(destination, probe.shown[0].settings)
        await settled(model)
        #expect(model.phase == .failed("boom"))
        #expect(service.runs.isEmpty)
        model.dismiss()
        #expect(model.phase == .idle)
    }

    @Test func dismissingWhileRunningDoesNothing() async {
        let service = FakeExportService(gated: true)
        let probe = PanelProbe()
        let model = model(service, probe: probe)
        model.exportSelection(["a"])
        probe.answer?(destination, probe.shown[0].settings)
        await Task.yield()
        model.dismiss()
        #expect(model.isRunning)
        service.open()
        await settled(model)
        model.dismiss()
        #expect(model.phase == .idle)
    }

    // MARK: - Report

    @Test func reportListsLockedAndMissing() {
        let report = ExportJobReport(
            exported: 3, skippedLocked: 2, missingAttachments: ["n1/photo.jpg", "n2/scan.pdf"],
            errors: ["Plan: disk full"], destination: destination)
        let summary = ExportReportSummary(report, wasCancelled: false)
        #expect(summary.headline == "3 notes exported.")
        #expect(summary.lockedLine == "2 locked notes were not exported")
        #expect(summary.missingAttachments == ["n1/photo.jpg", "n2/scan.pdf"])
        #expect(summary.errors == ["Plan: disk full"])
        #expect(summary.destination == destination)

        let one = ExportReportSummary(
            ExportJobReport(exported: 1, skippedLocked: 1, destination: destination), wasCancelled: false)
        #expect(one.headline == "1 note exported.")
        #expect(one.lockedLine == "1 locked note was not exported")
        #expect(one.missingAttachments.isEmpty)

        let clean = ExportReportSummary(ExportJobReport(exported: 2, destination: destination), wasCancelled: false)
        #expect(clean.lockedLine == nil)

        let nothing = ExportReportSummary(
            ExportJobReport(exported: 0, skippedLocked: 2, destination: destination), wasCancelled: false)
        #expect(nothing.headline == "Nothing was exported.")
        #expect(nothing.lockedLine == "2 locked notes were not exported")
    }

    @Test func theFinishedPhaseCarriesTheJobsReport() async {
        let service = FakeExportService()
        service.report = {
            ExportJobReport(exported: 1, skippedLocked: 1, missingAttachments: ["a/x.png"], destination: $0)
        }
        let probe = PanelProbe()
        let model = model(service, probe: probe)
        model.exportSelection(["a"])
        probe.answer?(destination, probe.shown[0].settings)
        await settled(model)
        guard case .finished(let report) = model.phase else { Issue.record("expected finished, got \(model.phase)"); return }
        #expect(report.destination == destination)
        #expect(report.skippedLocked == 1)
        #expect(report.missingAttachments == ["a/x.png"])
        #expect(!model.wasCancelled)
    }

    // MARK: - Closing the window

    @Test func closingWhileRunningCancelsTheRunAndLeavesTheModelIdle() async {
        let service = FakeExportService(gated: true)
        let probe = PanelProbe()
        let model = model(service, probe: probe)
        model.exportSelection(["a"])
        probe.answer?(destination, probe.shown[0].settings)
        await Task.yield()
        #expect(model.isRunning)
        model.close()
        service.open()
        await settled(model)
        #expect(service.sawCancelled)
        #expect(model.phase == .idle)
        #expect(!model.showsSheet)
        // A closed model starts nothing more.
        model.exportSelection(["a"])
        #expect(probe.shown.count == 1)
    }

    @Test func aPanelAnsweredAfterTheWindowClosedStartsNothing() {
        let service = FakeExportService()
        let probe = PanelProbe()
        let model = model(service, probe: probe)
        model.exportSelection(["a"])
        model.close()
        probe.answer?(destination, probe.shown[0].settings)
        #expect(service.runs.isEmpty)
        #expect(model.phase == .idle)
    }

    /// The real job: closing the window state right after the start rolls the run back, so the
    /// destination holds nothing from it and no sheet-less job keeps working.
    @Test func closingTheWindowStateCancelsALiveExportAndNothingRemains() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BaerchenExportClose-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(paths: AppPaths(root: root))
        let ids = try (1...5).map { try environment.store.create(text: "Note \($0)").id }
        let probe = PanelProbe()
        let state = MainWindowState(
            environment: environment, defaults: UserDefaults(suiteName: "ExportClose-\(UUID().uuidString)")!,
            exportPanel: { title, settings, completion, cancelled in
                probe.shown.append((title, settings))
                probe.answer = completion
                probe.cancel = cancelled
            })
        let out = root.appendingPathComponent("out", isDirectory: true)
        state.exporter.exportSelection(ids)
        probe.answer?(out, probe.shown[0].settings)
        #expect(state.exporter.isRunning)
        state.close()
        await state.exporter.runTask?.value
        #expect(state.exporter.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}
