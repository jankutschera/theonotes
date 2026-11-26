// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// Where `addTag` and new notes in a selected tag put the tag.
public enum TagPosition: String, Codable, Sendable, CaseIterable {
    case top, bottom
}

public enum NoteSort: String, Codable, Sendable, CaseIterable {
    case modifiedDescending, modifiedAscending
    case createdDescending, createdAscending
    case titleAscending, titleDescending
}

/// A typed setting: its row key in `setting` and the value used when the row is missing or
/// does not decode.
public struct SettingKey<Value: Codable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

extension SettingKey where Value == Bool {
    public static var hideMarkdown: SettingKey<Bool> { .init("hideMarkdown", default: true) }
    public static var showNoteCounts: SettingKey<Bool> { .init("showNoteCounts", default: true) }
    /// Checked todos move to the end of their checklist (Settings ▸ General).
    public static var autoSortTodos: SettingKey<Bool> { .init("autoSortTodos", default: false) }
    /// The H1…H6 level badges in the editor's left margin.
    public static var showHeadingLevels: SettingKey<Bool> { .init("showHeadingLevels", default: true) }
    /// Runs "Pull from Bear" right after launch.
    public static var pullFromBearAtLaunch: SettingKey<Bool> { .init("pullFromBearAtLaunch", default: false) }
    /// The editor completes tags (`#`), note titles and headings (`[[`) and emoji (`:`).
    public static var autocomplete: SettingKey<Bool> { .init("autocomplete", default: true) }
    /// Typewriter mode (Edit ▸ Typewriter Mode, ⌃⌘T; M6 Task 14): the caret line stays at the
    /// vertical centre of the editor. App-wide.
    public static var typewriterMode: SettingKey<Bool> { .init("typewriterMode", default: false) }
    /// Settings ▸ General "Keep tags when exporting": off drops tags from exported files.
    public static var keepTagsOnExport: SettingKey<Bool> { .init("keepTagsOnExport", default: true) }
    /// Mac: keep the unlocked note key in the Keychain behind Touch ID so a relaunch can unlock
    /// without the password. Opt-in: off until the user turns it on, so no Keychain item
    /// exists before explicit consent. Device-local; never part of `Settings.Snapshot`.
    public static var useTouchIDForNotes: SettingKey<Bool> { .init("useTouchIDForNotes", default: false) }
    /// Mac: require Touch ID or the Mac password to open the app (App Lock). Off until the
    /// user turns it on. Device-local; never part of `Settings.Snapshot`.
    public static var appLockEnabled: SettingKey<Bool> { .init("appLockEnabled", default: false) }
}

extension SettingKey where Value == Int {
    /// Mac: seconds the app may stay in the background before protected notes lock again
    /// (`Settings.noteRelockDelayOptions`; 0 = at once). Device-local; never part of `Settings.Snapshot`.
    public static var noteRelockDelay: SettingKey<Int> { .init("noteRelockDelay", default: 0) }
    /// Mac: seconds of inactivity (app in the background, or no input while it is in front) before the
    /// app locks again (`Settings.appLockDelayOptions`; 0 = as soon as it leaves the front). Device-local.
    public static var appLockDelay: SettingKey<Int> { .init("appLockDelay", default: 300) }
}

extension SettingKey where Value == Double {
    /// The editor zoom (View > Zoom In/Out/Actual Size, M7 Task 10); 1.0 is 100%.
    public static var editorZoom: SettingKey<Double> { .init("editorZoom", default: 1.0) }
}

extension SettingKey where Value == AppearanceMode {
    /// Settings > Appearance: follow the system, or force light or dark.
    public static var appearanceMode: SettingKey<AppearanceMode> { .init("appearanceMode", default: .system) }
}

extension SettingKey where Value == TypographySettings {
    public static var typography: SettingKey<TypographySettings> { .init("typography", default: .default) }
}

extension SettingKey where Value == String {
    /// The theme id used while the app looks light (`ThemeCatalog`).
    public static var lightTheme: SettingKey<String> { .init("lightTheme", default: ThemeCatalog.defaultLightId) }
    /// The theme id used while the app looks dark.
    public static var darkTheme: SettingKey<String> { .init("darkTheme", default: ThemeCatalog.defaultDarkId) }
    /// The `bearcli` executable used by Import from Bear / Pull from Bear.
    public static var bearCLIPath: SettingKey<String> {
        .init("bearCLIPath", default: "/Applications/Bear.app/Contents/MacOS/bearcli")
    }
    /// "Start new notes with: Template…" (spec §4.10): the id of a template note, "" for none.
    public static var startNoteTemplate: SettingKey<String> { .init("startNoteTemplate", default: "") }
    /// The x-callback API token (`XXXXXX-XXXXXX-XXXXXX`, M5 Task 13); "" until first generated.
    /// Deliberately not part of `Settings.Snapshot`: a secret must not travel with the UI state.
    public static var automationToken: SettingKey<String> { .init("automationToken", default: "") }
}

extension SettingKey where Value == TagPosition {
    public static var tagPosition: SettingKey<TagPosition> { .init("tagPosition", default: .bottom) }
}

extension SettingKey where Value == NoteSort {
    public static var noteSort: SettingKey<NoteSort> { .init("noteSort", default: .modifiedDescending) }
}

/// Typed accessors over the `setting` table; each value is stored as JSON (`true`, `"bottom"`).
///
/// The properties read and write the database on every access: a failed read yields the default,
/// a failed write is logged (use `set(_:to:)` to handle the error). `observe()` is a GRDB
/// `ValueObservation`, so it sees writes made through this process's `AppDatabase` only; other
/// processes' writes arrive via `ChangeNotifier` + `snapshot()`.
public struct Settings: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var hideMarkdown: Bool
        public var tagPosition: TagPosition
        public var noteSort: NoteSort
        public var showNoteCounts: Bool
        public var bearCLIPath: String
        public var pullFromBearAtLaunch: Bool
        public var autocomplete: Bool
        public var autoSortTodos: Bool
        public var showHeadingLevels: Bool
        /// The template note ⌘N starts from ("" for none).
        public var startNoteTemplate: String
        public var typewriterMode: Bool
        public var keepTagsOnExport: Bool
        public var appearanceMode: AppearanceMode
        public var lightTheme: String
        public var darkTheme: String
        public var typography: TypographySettings
        public var editorZoom: Double

        public init(
            hideMarkdown: Bool = SettingKey<Bool>.hideMarkdown.defaultValue,
            tagPosition: TagPosition = SettingKey<TagPosition>.tagPosition.defaultValue,
            noteSort: NoteSort = SettingKey<NoteSort>.noteSort.defaultValue,
            showNoteCounts: Bool = SettingKey<Bool>.showNoteCounts.defaultValue,
            bearCLIPath: String = SettingKey<String>.bearCLIPath.defaultValue,
            pullFromBearAtLaunch: Bool = SettingKey<Bool>.pullFromBearAtLaunch.defaultValue,
            autocomplete: Bool = SettingKey<Bool>.autocomplete.defaultValue,
            autoSortTodos: Bool = SettingKey<Bool>.autoSortTodos.defaultValue,
            showHeadingLevels: Bool = SettingKey<Bool>.showHeadingLevels.defaultValue,
            startNoteTemplate: String = SettingKey<String>.startNoteTemplate.defaultValue,
            typewriterMode: Bool = SettingKey<Bool>.typewriterMode.defaultValue,
            keepTagsOnExport: Bool = SettingKey<Bool>.keepTagsOnExport.defaultValue,
            appearanceMode: AppearanceMode = SettingKey<AppearanceMode>.appearanceMode.defaultValue,
            lightTheme: String = SettingKey<String>.lightTheme.defaultValue,
            darkTheme: String = SettingKey<String>.darkTheme.defaultValue,
            typography: TypographySettings = SettingKey<TypographySettings>.typography.defaultValue,
            editorZoom: Double = SettingKey<Double>.editorZoom.defaultValue
        ) {
            self.hideMarkdown = hideMarkdown
            self.tagPosition = tagPosition
            self.noteSort = noteSort
            self.showNoteCounts = showNoteCounts
            self.bearCLIPath = bearCLIPath
            self.pullFromBearAtLaunch = pullFromBearAtLaunch
            self.autocomplete = autocomplete
            self.autoSortTodos = autoSortTodos
            self.showHeadingLevels = showHeadingLevels
            self.startNoteTemplate = startNoteTemplate
            self.typewriterMode = typewriterMode
            self.keepTagsOnExport = keepTagsOnExport
            self.appearanceMode = appearanceMode
            self.lightTheme = lightTheme
            self.darkTheme = darkTheme
            self.typography = typography
            self.editorZoom = editorZoom
        }
    }

    private let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    public var hideMarkdown: Bool {
        get { read(.hideMarkdown) }
        nonmutating set { write(.hideMarkdown, newValue) }
    }

    public var tagPosition: TagPosition {
        get { read(.tagPosition) }
        nonmutating set { write(.tagPosition, newValue) }
    }

    public var noteSort: NoteSort {
        get { read(.noteSort) }
        nonmutating set { write(.noteSort, newValue) }
    }

    public var showNoteCounts: Bool {
        get { read(.showNoteCounts) }
        nonmutating set { write(.showNoteCounts, newValue) }
    }

    public var autocomplete: Bool {
        get { read(.autocomplete) }
        nonmutating set { write(.autocomplete, newValue) }
    }

    public var autoSortTodos: Bool {
        get { read(.autoSortTodos) }
        nonmutating set { write(.autoSortTodos, newValue) }
    }

    public var showHeadingLevels: Bool {
        get { read(.showHeadingLevels) }
        nonmutating set { write(.showHeadingLevels, newValue) }
    }

    public var typewriterMode: Bool {
        get { read(.typewriterMode) }
        nonmutating set { write(.typewriterMode, newValue) }
    }

    public var keepTagsOnExport: Bool {
        get { read(.keepTagsOnExport) }
        nonmutating set { write(.keepTagsOnExport, newValue) }
    }

    public var appearanceMode: AppearanceMode {
        get { read(.appearanceMode) }
        nonmutating set { write(.appearanceMode, newValue) }
    }

    public var lightTheme: String {
        get { read(.lightTheme) }
        nonmutating set { write(.lightTheme, newValue) }
    }

    public var darkTheme: String {
        get { read(.darkTheme) }
        nonmutating set { write(.darkTheme, newValue) }
    }

    public var typography: TypographySettings {
        get { read(.typography) }
        nonmutating set { write(.typography, newValue) }
    }

    public var editorZoom: Double {
        get { read(.editorZoom) }
        nonmutating set { write(.editorZoom, newValue) }
    }

    /// The relock delays the app offers, in seconds.
    public static let noteRelockDelayOptions = [0, 60, 300, 900, 3600]

    /// A stored value outside `noteRelockDelayOptions` counts as 0 (lock at once); a setter call
    /// with such a value is ignored.
    public var noteRelockDelay: Int {
        get {
            let stored = read(.noteRelockDelay)
            return Self.noteRelockDelayOptions.contains(stored) ? stored : 0
        }
        nonmutating set {
            guard Self.noteRelockDelayOptions.contains(newValue) else { return }
            write(.noteRelockDelay, newValue)
        }
    }

    public var useTouchIDForNotes: Bool {
        get { read(.useTouchIDForNotes) }
        nonmutating set { write(.useTouchIDForNotes, newValue) }
    }

    public var appLockEnabled: Bool {
        get { read(.appLockEnabled) }
        nonmutating set { write(.appLockEnabled, newValue) }
    }

    /// The App Lock delays the app offers, in seconds.
    public static let appLockDelayOptions = [0, 60, 300, 900, 3600]

    /// A stored value outside `appLockDelayOptions` counts as the default (5 minutes); a setter call
    /// with such a value is ignored.
    public var appLockDelay: Int {
        get {
            let stored = read(.appLockDelay)
            return Self.appLockDelayOptions.contains(stored) ? stored : SettingKey<Int>.appLockDelay.defaultValue
        }
        nonmutating set {
            guard Self.appLockDelayOptions.contains(newValue) else { return }
            write(.appLockDelay, newValue)
        }
    }

    public func value<Value>(_ key: SettingKey<Value>) throws -> Value {
        try db.pool.read { try Self.value(key, in: $0) }
    }

    public func set<Value>(_ key: SettingKey<Value>, to value: Value) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.pool.write { db in
            try db.execute(
                sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key.name, json]
            )
        }
    }

    public func snapshot() throws -> Snapshot {
        try db.pool.read(Self.snapshot)
    }

    /// Emits the current snapshot, then a new one after each committed change to `setting`.
    public func observe() -> AsyncValueObservation<Snapshot> {
        ValueObservation.tracking(Self.snapshot).removeDuplicates().values(in: db.pool)
    }

    private static func snapshot(_ db: Database) throws -> Snapshot {
        Snapshot(
            hideMarkdown: try value(.hideMarkdown, in: db),
            tagPosition: try value(.tagPosition, in: db),
            noteSort: try value(.noteSort, in: db),
            showNoteCounts: try value(.showNoteCounts, in: db),
            bearCLIPath: try value(.bearCLIPath, in: db),
            pullFromBearAtLaunch: try value(.pullFromBearAtLaunch, in: db),
            autocomplete: try value(.autocomplete, in: db),
            autoSortTodos: try value(.autoSortTodos, in: db),
            showHeadingLevels: try value(.showHeadingLevels, in: db),
            startNoteTemplate: try value(.startNoteTemplate, in: db),
            typewriterMode: try value(.typewriterMode, in: db),
            keepTagsOnExport: try value(.keepTagsOnExport, in: db),
            appearanceMode: try value(.appearanceMode, in: db),
            lightTheme: try value(.lightTheme, in: db),
            darkTheme: try value(.darkTheme, in: db),
            typography: try value(.typography, in: db),
            editorZoom: try value(.editorZoom, in: db)
        )
    }

    static func value<Value>(_ key: SettingKey<Value>, in db: Database) throws -> Value {
        guard let json = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key.name])
        else { return key.defaultValue }
        do {
            return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        } catch {
            storeLogger.error("setting \(key.name, privacy: .public) undecodable, using default: \(error)")
            return key.defaultValue
        }
    }

    private func read<Value>(_ key: SettingKey<Value>) -> Value {
        do {
            return try value(key)
        } catch {
            storeLogger.error("setting \(key.name, privacy: .public) unreadable, using default: \(error)")
            return key.defaultValue
        }
    }

    private func write<Value>(_ key: SettingKey<Value>, _ value: Value) {
        do {
            try set(key, to: value)
        } catch {
            storeLogger.error("setting \(key.name, privacy: .public) not saved: \(error)")
        }
    }
}
