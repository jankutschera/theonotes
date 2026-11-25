// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import WidgetKit

struct MobileWidgetSelections: Equatable {
    var notes: Set<String> = []
    var tags: Set<String> = []

    mutating func addNote(library: String, id: String, activeLibrary: String) {
        if library == activeLibrary { notes.insert(id) }
    }

    mutating func addTag(library: String, tag: String?, activeLibrary: String) {
        if library == activeLibrary, let tag { tags.insert(tag) }
    }
}

@MainActor enum MobileWidgetConfigurations {
    static func current(libraryID: String) async throws -> MobileWidgetSelections {
        let configurations = try await WidgetCenter.shared.currentConfigurations()
        var result = MobileWidgetSelections()
        for configuration in configurations {
            if let parts = configuration.widgetConfigurationIntent(of: PinnedNoteConfiguration.self)?.note?.parts {
                result.addNote(library: parts.library, id: parts.note, activeLibrary: libraryID)
            }
            if let parts = configuration.widgetConfigurationIntent(of: NoteListConfiguration.self)?.list?.parts {
                result.addTag(library: parts.library, tag: parts.tag, activeLibrary: libraryID)
            }
        }
        return result
    }
}
