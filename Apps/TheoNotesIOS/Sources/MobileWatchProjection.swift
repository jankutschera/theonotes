// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import TheoNotesCore

/// Read only unlocked, active notes; never project a locally unlocked protected note.
@MainActor enum MobileWatchProjection {
    static func notes(library: MobileLibrary) throws -> [WatchWireNote] {
        guard !library.appLockEnabled, !library.appLocked, !library.isClosed, !library.isClosing,
              !library.libraryOperationBusy else { return [] }
        let notes = try library.database.pool.read { db in
            try Note.fetchAll(db, sql: """
                SELECT * FROM note WHERE location='notes' AND deletedAt IS NULL AND NOT isLocked
                ORDER BY modifiedAt DESC, id LIMIT 15
                """)
        }
        var output: [WatchWireNote] = [], totalBytes = 0, taskCount = 0
        for note in notes {
            guard UUID(uuidString: note.id) != nil, note.revision >= 0, note.revision < Int.max - 1,
                  !note.text.contains("\0"), note.text.utf8.count <= 32_768 else { continue }
            let title = bounded(note.title, limit: 256)
            let budget = 131_072 - totalBytes - note.text.utf8.count - title.utf8.count
            guard budget >= 0 else { break }
            let tasks = taskCount < 256 ? makeTasks(note.text, limit: min(64, 256 - taskCount), budget: budget) : []
            totalBytes += title.utf8.count + note.text.utf8.count + tasks.reduce(0) { $0 + $1.title.utf8.count }
            taskCount += tasks.count
            output.append(.init(id: note.id, revision: note.revision, title: title, text: note.text, tasks: tasks))
        }
        return output
    }

    private static func makeTasks(_ text: String, limit: Int, budget: Int) -> [WatchWireTask] {
        let eligible = Dictionary(uniqueKeysWithValues: TodoLines.all(in: text).map { ($0.line, $0) })
        guard !eligible.isEmpty else { return [] }
        let full = text as NSString
        let pattern = try? NSRegularExpression(pattern: #"\[[ xX]\]"#)
        let hash = WatchNoteCommand.fingerprint(text)
        var result: [WatchWireTask] = [], line = 1, offset = 0, bytes = 0
        while offset < full.length && result.count < limit {
            let range = full.lineRange(for: NSRange(location: offset, length: 0))
            guard range.length > 0 else { break }
            if let task = eligible[line], let marker = pattern?.firstMatch(in: text, range: range)?.range {
                let title = bounded(task.text, limit: 256)
                guard bytes + title.utf8.count <= budget else { break }
                result.append(.init(title: title, isChecked: task.isDone, sourceSHA256: hash,
                                    utf16Offset: marker.location, expectedMarker: full.substring(with: marker)))
                bytes += title.utf8.count
            }
            offset = NSMaxRange(range); line += 1
        }
        return result
    }
    private static func bounded(_ text: String, limit: Int) -> String {
        var output = String.UnicodeScalarView(), count = 0
        for scalar in text.unicodeScalars where scalar.value != 0 {
            let size = String(scalar).utf8.count
            guard count + size <= limit else { break }
            output.append(scalar); count += size
        }
        return String(output)
    }
}
