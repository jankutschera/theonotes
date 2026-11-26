// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

@Suite struct SettingsTests {
    @Test func testDefaults() throws {
        let settings = Settings(db: try .inMemory())
        #expect(settings.hideMarkdown == true)
        #expect(settings.tagPosition == .bottom)
        #expect(settings.noteSort == .modifiedDescending)
        #expect(settings.showNoteCounts == true)
        #expect(try settings.value(.bearCLIPath) == "/Applications/Bear.app/Contents/MacOS/bearcli")
        #expect(try settings.value(.pullFromBearAtLaunch) == false)
        #expect(settings.autoSortTodos == false)
        #expect(settings.showHeadingLevels == true)
        #expect(try settings.value(.startNoteTemplate) == "")
        #expect(try settings.snapshot() == Settings.Snapshot())
    }

    /// M3 Task 7: tag, note, heading and emoji completion; on by default.
    @Test func testAutocompleteSetting() throws {
        let db = try AppDatabase.inMemory()
        let settings = Settings(db: db)
        #expect(settings.autocomplete == true)
        #expect(try settings.snapshot().autocomplete == true)
        settings.autocomplete = false
        #expect(Settings(db: db).autocomplete == false)
        #expect(try settings.snapshot().autocomplete == false)
    }

    /// M6 Task 14: Typewriter Mode is off until the user turns it on (Edit menu or Settings).
    @Test func typewriterModeDefaultsOff() throws {
        let db = try AppDatabase.inMemory()
        let settings = Settings(db: db)
        #expect(SettingKey<Bool>.typewriterMode.defaultValue == false)
        #expect(settings.typewriterMode == false)
        #expect(try settings.snapshot().typewriterMode == false)
        settings.typewriterMode = true
        #expect(Settings(db: db).typewriterMode == true)
        #expect(try settings.snapshot().typewriterMode == true)
        #expect(try settings.snapshot() == Settings.Snapshot(typewriterMode: true))
        try settings.set(.typewriterMode, to: false)
        #expect(try settings.snapshot().typewriterMode == false)
    }

    /// M8 Task 1: "Keep tags when exporting" is on until the user turns it off.
    @Test func keepTagsOnExportDefaultsToTrueAndRoundTrips() throws {
        let db = try AppDatabase.inMemory()
        let settings = Settings(db: db)
        #expect(SettingKey<Bool>.keepTagsOnExport.defaultValue == true)
        #expect(settings.keepTagsOnExport == true)
        #expect(try settings.snapshot().keepTagsOnExport == true)
        settings.keepTagsOnExport = false
        #expect(Settings(db: db).keepTagsOnExport == false)
        #expect(try settings.snapshot().keepTagsOnExport == false)
        #expect(try settings.snapshot() == Settings.Snapshot(keepTagsOnExport: false))
        try settings.set(.keepTagsOnExport, to: true)
        #expect(try settings.snapshot() == Settings.Snapshot())
    }

    /// M7 Task 7: appearance keys default to the system mode, the two Theo Notes themes, default typography and 100% zoom.
    @Test func testAppearanceKeysDefaultsAndRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let settings = Settings(db: db)
        #expect(settings.appearanceMode == .system)
        #expect(settings.lightTheme == "baerchen-red")
        #expect(settings.darkTheme == "baerchen-dark")
        #expect(settings.typography == .default)
        #expect(settings.editorZoom == 1.0)
        #expect(try settings.snapshot() == Settings.Snapshot())

        var typography = TypographySettings.default
        typography.fontText = "Georgia"
        typography.fontSize = 18
        settings.appearanceMode = .dark
        settings.lightTheme = "dracula"
        settings.darkTheme = "oled-black"
        settings.typography = typography
        settings.editorZoom = 1.25
        let reread = Settings(db: db)
        #expect(reread.appearanceMode == .dark)
        #expect(reread.lightTheme == "dracula")
        #expect(reread.darkTheme == "oled-black")
        #expect(reread.typography == typography)
        #expect(reread.editorZoom == 1.25)
        #expect(
            try reread.snapshot()
                == Settings.Snapshot(
                    appearanceMode: .dark, lightTheme: "dracula", darkTheme: "oled-black", typography: typography,
                    editorZoom: 1.25))
    }

    /// A stored value that does not decode reads as the default, and a typography row from an older build keeps
    /// the default for the field it lacks.
    @Test func testUndecodableAppearanceRowsReadAsDefaults() throws {
        let db = try AppDatabase.inMemory()
        try db.pool.write { db in
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('appearanceMode', '\"sepia\"')")
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('typography', '{\"fontSize\":20}')")
        }
        let snapshot = try Settings(db: db).snapshot()
        #expect(snapshot.appearanceMode == .system)
        #expect(snapshot.typography == TypographySettings(fontSize: 20))
    }

    /// The heading-level badges in the editor margin; on by default.
    @Test func testShowHeadingLevelsSetting() throws {
        let db = try AppDatabase.inMemory()
        let settings = Settings(db: db)
        #expect(settings.showHeadingLevels == true)
        #expect(try settings.snapshot().showHeadingLevels == true)
        settings.showHeadingLevels = false
        #expect(Settings(db: db).showHeadingLevels == false)
        #expect(try settings.snapshot().showHeadingLevels == false)
        #expect(try settings.snapshot() == Settings.Snapshot(showHeadingLevels: false))
        try settings.set(.showHeadingLevels, to: true)
        #expect(try settings.snapshot().showHeadingLevels == true)
    }

    @Test func testRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let settings = Settings(db: db)
        settings.hideMarkdown = false
        settings.tagPosition = .top
        settings.noteSort = .titleAscending
        try settings.set(.showNoteCounts, to: false)

        let reread = Settings(db: db)
        #expect(reread.hideMarkdown == false)
        #expect(reread.tagPosition == .top)
        #expect(reread.noteSort == .titleAscending)
        #expect(try reread.value(.showNoteCounts) == false)
        settings.autoSortTodos = true
        #expect(reread.autoSortTodos == true)
        #expect(try reread.snapshot().autoSortTodos == true)
        try settings.set(.autoSortTodos, to: false)
        let stored = try db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT key, value FROM setting ORDER BY key").map { "\($0[0] as String)=\($0[1] as String)" }
        }
        #expect(stored == ["autoSortTodos=false", "hideMarkdown=false", "noteSort=\"titleAscending\"", "showNoteCounts=false", "tagPosition=\"top\""])
    }

    @Test func testUndecodableValueFallsBackToDefault() throws {
        let db = try AppDatabase.inMemory()
        try db.pool.write { try $0.execute(sql: "INSERT INTO setting (key, value) VALUES ('tagPosition', '\"sideways\"')") }
        #expect(Settings(db: db).tagPosition == .bottom)
    }

    @Test func testObserveEmitsChanges() async throws {
        let db = try AppDatabase.inMemory()
        let settings = Settings(db: db)
        var iterator = settings.observe().makeAsyncIterator()
        #expect(try await iterator.next() == Settings.Snapshot())
        settings.tagPosition = .top
        let next = try #require(try await iterator.next())
        #expect(next.tagPosition == .top)
    }

    @Test func testImportSettingsRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let settings = Settings(db: db)
        try settings.set(.bearCLIPath, to: "/opt/bear/bearcli")
        try settings.set(.pullFromBearAtLaunch, to: true)
        let snapshot = try Settings(db: db).snapshot()
        #expect(snapshot.bearCLIPath == "/opt/bear/bearcli")
        #expect(snapshot.pullFromBearAtLaunch == true)
    }

    @Test func testStartNoteTemplateRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        try Settings(db: db).set(.startNoteTemplate, to: "note-id-1")
        #expect(try Settings(db: db).snapshot().startNoteTemplate == "note-id-1")
        try Settings(db: db).set(.startNoteTemplate, to: "")
        #expect(try Settings(db: db).snapshot() == Settings.Snapshot())
    }

    /// Note relock delay (seconds) and the Touch ID cache opt-in. Device-local settings.
    @Test func noteRelockDelayDefaultsToImmediateAndOnlyKeepsKnownChoices() throws {
        let db = try AppDatabase.inMemory()
        let settings = Settings(db: db)
        #expect(SettingKey<Int>.noteRelockDelay.defaultValue == 0)
        #expect(Settings.noteRelockDelayOptions == [0, 60, 300, 900, 3600])
        #expect(settings.noteRelockDelay == 0)
        settings.noteRelockDelay = 300
        #expect(Settings(db: db).noteRelockDelay == 300)
        // A value outside the offered choices is never written, and one found in the table counts as 0.
        settings.noteRelockDelay = 7
        #expect(Settings(db: db).noteRelockDelay == 300)
        try settings.set(.noteRelockDelay, to: 99_999)
        #expect(settings.noteRelockDelay == 0)
        try settings.set(.noteRelockDelay, to: -5)
        #expect(settings.noteRelockDelay == 0)
    }

    @Test func touchIDForNotesIsOptInAndRoundTrips() throws {
        let db = try AppDatabase.inMemory()
        let settings = Settings(db: db)
        #expect(SettingKey<Bool>.useTouchIDForNotes.defaultValue == false)
        #expect(settings.useTouchIDForNotes == false)
        settings.useTouchIDForNotes = true
        #expect(Settings(db: db).useTouchIDForNotes == true)
        // Neither value travels in the UI snapshot.
        #expect(try settings.snapshot() == Settings.Snapshot())
    }
    /// The app lock settings. Device-local, off by default, same delay choices as the note relock.
    @Test func appLockIsOffByDefaultAndKeepsOnlyKnownDelays() throws {
        let db = try AppDatabase.inMemory()
        let settings = Settings(db: db)
        #expect(SettingKey<Bool>.appLockEnabled.defaultValue == false)
        #expect(SettingKey<Int>.appLockDelay.defaultValue == 300)
        #expect(Settings.appLockDelayOptions == [0, 60, 300, 900, 3600])
        #expect(settings.appLockEnabled == false)
        #expect(settings.appLockDelay == 300)
        settings.appLockEnabled = true
        settings.appLockDelay = 900
        #expect(Settings(db: db).appLockEnabled == true)
        #expect(Settings(db: db).appLockDelay == 900)
        // A value outside the offered choices is never written; one found in the table falls back to the default.
        settings.appLockDelay = 7
        #expect(Settings(db: db).appLockDelay == 900)
        try settings.set(.appLockDelay, to: -1)
        #expect(settings.appLockDelay == 300)
        // Neither value travels in the UI snapshot.
        #expect(try settings.snapshot() == Settings.Snapshot())
    }
}
