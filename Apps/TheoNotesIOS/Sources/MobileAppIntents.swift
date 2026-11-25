// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppIntents
import TheoNotesCore
import Foundation
import UIKit
import UniformTypeIdentifiers

/// Uses the same library and journals as the visible app, including recovery-library switches.
/// Entity resolution must never open a second store or bypass the app lock.
@MainActor enum MobileShortcutRuntime {
    private(set) static var service: MobileShortcutService?
    private(set) static var capture: MobileShortcutCapture?
    static let captureRouter = MobileCaptureRouter()

    static func connect(_ library: MobileLibrary?) {
        service = library.map(MobileShortcutService.init(library:))
        capture = library.map(MobileShortcutCapture.init(library:))
        captureRouter.connect(library, ready: false)
    }

    static func requireService() throws -> MobileShortcutService {
        guard let service else { throw MobileShortcutUnavailable() }
        return service
    }
}

private struct MobileShortcutUnavailable: LocalizedError {
    var errorDescription: String? { "Open Theo Notes and unlock your library, then run the shortcut again." }
}

struct ShortcutNote: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Note"
    static let defaultQuery = ShortcutNoteQuery()
    let id: String
    let title: String

    init(_ note: Note) { id = note.id; title = note.title }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title.isEmpty ? "Untitled Note" : title)")
    }
}

struct ShortcutNoteQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [ShortcutNote] {
        guard let service = MobileShortcutRuntime.service else { return [] }
        // Resolve saved identifiers against current privacy/deletion state, never cached titles.
        return identifiers.prefix(100).compactMap { id in
            guard let note = try? service.note(id: id) else { return nil }
            return ShortcutNote(note)
        }
    }

    @MainActor func suggestedEntities() async throws -> [ShortcutNote] {
        guard let service = MobileShortcutRuntime.service else { return [] }
        return (try? service.find(query: "", limit: 50).map(ShortcutNote.init)) ?? []
    }

    @MainActor func entities(matching string: String) async throws -> [ShortcutNote] {
        guard let service = MobileShortcutRuntime.service else { return [] }
        return try service.find(query: string, limit: 50).map(ShortcutNote.init)
    }
}

struct SaveToBaerchen: AppIntent {
    static let title: LocalizedStringResource = "Save to Theo Notes"
    static let description = IntentDescription("Save shared text, links, images or files as one note, choose a title automatically and copy its link. Returns the note link. Shortcuts may download web addresses as files. Pass a URL as text to save just the link. Enable Show in Share Sheet in your shortcut to use it from other apps.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Content", supportedContentTypes: [.item], inputConnectionBehavior: .connectToPreviousIntentResult)
    var content: [IntentFile]
    @Parameter(title: "Title", description: "Leave empty to use the first text line or filename.") var noteTitle: String?
    @Parameter(title: "Copy Note Link", default: true) var copyNoteLink: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$content) to Theo Notes") {
            \.$noteTitle
            \.$copyNoteLink
        }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<URL> {
        guard let capture = MobileShortcutRuntime.capture else { throw MobileShortcutUnavailable() }
        guard content.count <= 100 else { throw MobileShortcutCapture.Failure.tooLarge }
        var inputs: [MobileShortcutCapture.Input] = []
        var remaining = MobileShortcutCapture.maximumBytes
        for file in content {
            let data = file.data
            guard data.count <= remaining else { throw MobileShortcutCapture.Failure.tooLarge }
            remaining -= data.count
            inputs.append(.file(data: data, filename: file.filename, contentType: file.type))
        }
        let result = try capture.capture(inputs: inputs, title: noteTitle)
        if copyNoteLink { UIPasteboard.general.string = result.link.absoluteString }
        return .result(value: result.link)
    }
}

struct CreateShortcutNote: AppIntent {
    static let title: LocalizedStringResource = "Create Note"
    static let description = IntentDescription("Save text as a new Theo Notes note and return the note for use in other actions. Opens Theo Notes; protected notes are not exposed.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true)) var text: String
    @Parameter(title: "Title") var noteTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create a note with \(\.$text)") { \.$noteTitle }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<ShortcutNote> {
        let note = try MobileShortcutRuntime.requireService().create(text: text, title: noteTitle)
        return .result(value: ShortcutNote(note))
    }
}

struct AppendToShortcutNote: AppIntent {
    static let title: LocalizedStringResource = "Append Text to Note"
    static let description = IntentDescription("Append exact text to an editable Theo Notes note. Include a line break in the text if needed. Opens Theo Notes.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true)) var text: String
    @Parameter(title: "Note") var note: ShortcutNote

    static var parameterSummary: some ParameterSummary { Summary("Append \(\.$text) to \(\.$note)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<ShortcutNote> {
        let updated = try MobileShortcutRuntime.requireService().append(text: text, to: note.id)
        return .result(value: ShortcutNote(updated))
    }
}

struct FindShortcutNotes: AppIntent {
    static let title: LocalizedStringResource = "Find Notes"
    static let description = IntentDescription("Find up to 50 unprotected notes using Theo Notes search, including tags and search operators. Searches Notes and Archive across workspaces. Opens Theo Notes.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Search") var query: String
    static var parameterSummary: some ParameterSummary { Summary("Find notes matching \(\.$query)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[ShortcutNote]> {
        let notes = try MobileShortcutRuntime.requireService().find(query: query, limit: 50)
        return .result(value: notes.map(ShortcutNote.init))
    }
}

struct ReadShortcutNote: AppIntent {
    static let title: LocalizedStringResource = "Get Note Markdown"
    static let description = IntentDescription("Return the exact Markdown text of an unprotected note for the next shortcut action. Opens Theo Notes.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Note") var note: ShortcutNote
    static var parameterSummary: some ParameterSummary { Summary("Get Markdown from \(\.$note)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let current = try MobileShortcutRuntime.requireService().note(id: note.id)
        return .result(value: current.text)
    }
}

struct OpenShortcutNote: AppIntent {
    static let title: LocalizedStringResource = "Open Note"
    static let description = IntentDescription("Open an unprotected note in Theo Notes.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Note") var note: ShortcutNote
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$note)") }

    @MainActor func perform() async throws -> some IntentResult {
        try MobileShortcutRuntime.requireService().open(id: note.id)
        return .result()
    }
}

struct OpenBaerchenShortcut: AppIntent {
    static let title: LocalizedStringResource = "Open Theo Notes"
    static let description = IntentDescription("Open your Theo Notes library.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    func perform() async throws -> some IntentResult { .result() }
}

struct BaerchenAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SaveToBaerchen(), phrases: ["Save content to \(.applicationName)"],
                    shortTitle: "Save to Theo Notes", systemImageName: "square.and.arrow.down")
        AppShortcut(intent: CreateShortcutNote(), phrases: ["Create a note in \(.applicationName)"],
                    shortTitle: "New Note", systemImageName: "square.and.pencil")
        AppShortcut(intent: FindShortcutNotes(), phrases: ["Find notes in \(.applicationName)"],
                    shortTitle: "Find Notes", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenBaerchenShortcut(), phrases: ["Open \(.applicationName)"],
                    shortTitle: "Open Theo Notes", systemImageName: "note.text")
    }
}


enum MobileCaptureAction: String, CaseIterable, AppEnum {
    case newNote, newTodo, scan, search, thought
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Capture Action")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .newNote: "New Note", .newTodo: "New To-Do", .scan: "Scan Document",
        .search: "Search", .thought: "Thought",
    ]
    @MainActor var route: MobileCaptureRouter.Action {
        switch self {
        case .newNote: .newNote
        case .newTodo: .newTodo
        case .scan: .scan
        case .search: .search
        case .thought: .thought
        }
    }
}

/// UI capture has a separate contract from CreateShortcutNote's text-in/note-out automation.
struct CaptureInTheoNotes: AppIntent {
    static let title: LocalizedStringResource = "Open Capture Action"
    static let description = IntentDescription("Open a capture action in your unlocked Theo Notes library.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Action") var action: MobileCaptureAction
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$action)") }

    @MainActor func perform() async throws -> some IntentResult {
        let router = MobileShortcutRuntime.captureRouter
        router.enqueue(action.route, source: .shortcut)
        try await router.drain()
        return .result()
    }
}
