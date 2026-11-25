// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppIntents
import SwiftUI
import WidgetKit

extension WidgetCaptureAction: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Theo Notes Action"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .thought: "Thought", .voice: "Voice", .newNote: "New Note", .newTodo: "New To-Do", .scan: "Scan Document", .search: "Search",
    ]
}

/// This file must belong to BOTH app and extension. Only the app registers the delivery sink.
/// OpenIntent asks the system to execute in the containing app; extension fallback never reports success.
@MainActor enum WidgetCaptureRuntime {
    typealias Handler = @MainActor (WidgetCaptureAction, UUID) async throws -> Void
    static var handler: Handler?
    enum Unavailable: Error { case hostRuntime }
    static func deliver(_ action: WidgetCaptureAction, deliveryID: UUID) async throws {
        #if THEONOTES_WIDGET_EXTENSION
        throw Unavailable.hostRuntime
        #else
        guard let handler else { throw Unavailable.hostRuntime }
        try await handler(action, deliveryID)
        #endif
    }
}
struct WidgetCaptureIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Theo Notes Action"
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Action") var target: WidgetCaptureAction
    init() {}
    init(_ action: WidgetCaptureAction) { target = action }
    @MainActor func perform() async throws -> some IntentResult {
        try await WidgetCaptureRuntime.deliver(target, deliveryID: UUID())
        return .result()
    }
}

// Six distinct, stable gallery entries; every button uses the same tested host dispatch contract.
struct ThoughtControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TheoNotes.ThoughtControl") {
            ControlWidgetButton(action: WidgetCaptureIntent(.thought)) { Label("Thought", systemImage: "lightbulb") }
        }.displayName("Thought").description("Open a new thought in Theo Notes.")
    }
}
struct VoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TheoNotes.VoiceControl") {
            ControlWidgetButton(action: WidgetCaptureIntent(.voice)) { Label("Voice", systemImage: "mic") }
        }.displayName("Voice").description("Open voice capture in Theo Notes.")
    }
}
struct NewNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TheoNotes.NewNoteControl") {
            ControlWidgetButton(action: WidgetCaptureIntent(.newNote)) { Label("New Note", systemImage: "square.and.pencil") }
        }.displayName("New Note").description("Write a new note in Theo Notes.")
    }
}
struct NewTodoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TheoNotes.NewTodoControl") {
            ControlWidgetButton(action: WidgetCaptureIntent(.newTodo)) { Label("New To-Do", systemImage: "checklist") }
        }.displayName("New To-Do").description("Write a new to-do in Theo Notes.")
    }
}
struct ScanControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TheoNotes.ScanControl") {
            ControlWidgetButton(action: WidgetCaptureIntent(.scan)) { Label("Scan", systemImage: "doc.viewfinder") }
        }.displayName("Scan Document").description("Open the document scanner in Theo Notes.")
    }
}
struct SearchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TheoNotes.SearchControl") {
            ControlWidgetButton(action: WidgetCaptureIntent(.search)) { Label("Search", systemImage: "magnifyingglass") }
        }.displayName("Search").description("Search Theo Notes.")
    }
}
