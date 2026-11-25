// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
@testable import TheoNotesCore

/// Test double for bearcli. Serves `Fixtures/import/` by default; tests can replace the records,
/// add attachment blobs, and make single attachments fail. Mutable between pulls.
final class FakeBearCLI: BearCLIClient, @unchecked Sendable {
    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/import")

    private let lock = NSLock()
    private var _records: [BearNoteRecord]?
    private var _listErrors: [String] = []
    private var _readOnly: Set<String>
    private var _blobs: [String: Data] = [:]
    private var _failing: Set<String> = []

    init(readOnly: Set<String> = [], records: [BearNoteRecord]? = nil) {
        _readOnly = readOnly
        _records = records
    }

    var records: [BearNoteRecord] {
        get { lock.withLock { _records } ?? (try! fixtureList().records) }
        set { lock.withLock { _records = newValue } }
    }

    var readOnly: Set<String> {
        get { lock.withLock { _readOnly } }
        set { lock.withLock { _readOnly = newValue } }
    }

    var listErrors: [String] {
        get { lock.withLock { _listErrors } }
        set { lock.withLock { _listErrors = newValue } }
    }

    func setBlob(_ data: Data, noteID: String, filename: String) {
        lock.withLock { _blobs["\(noteID)/\(filename)"] = data }
    }

    /// `attachmentData` for this attachment throws `BearCLIError.failed`.
    func fail(noteID: String, filename: String) {
        lock.withLock { _ = _failing.insert("\(noteID)/\(filename)") }
    }

    func clearFailures() { lock.withLock { _failing = [] } }

    private var _onAttachmentData: ((String, String) -> Void)?

    /// Runs on every `attachmentData(noteID:filename:)` call, before the bytes are returned:
    /// stands in for something happening in Theo Notes while a pull fetches attachments.
    var onAttachmentData: ((String, String) -> Void)? {
        get { lock.withLock { _onAttachmentData } }
        set { lock.withLock { _onAttachmentData = newValue } }
    }

    private func fixtureList() throws -> BearNoteList {
        try BearNoteRecord.decodeList(Data(contentsOf: Self.fixtureDir.appendingPathComponent("bearcli-list.json")))
    }

    func listAll() throws -> BearNoteList {
        if let records = lock.withLock({ _records }) {
            return BearNoteList(records: records, errors: listErrors)
        }
        var list = try fixtureList()
        list.errors += listErrors
        return list
    }

    func readOnlyIDs() throws -> Set<String> { readOnly }

    func attachmentData(noteID: String, filename: String) throws -> Data {
        let key = "\(noteID)/\(filename)"
        onAttachmentData?(noteID, filename)
        let (failing, blob) = lock.withLock { (_failing.contains(key), _blobs[key]) }
        if failing { throw BearCLIError.failed(code: 1, stderr: "simulated failure") }
        if let blob { return blob }
        let url = Self.fixtureDir.appendingPathComponent("attachments/\(noteID)/\(filename)")
        guard let data = try? Data(contentsOf: url) else {
            throw BearCLIError.bear(code: "attachment_not_found", message: "no such attachment")
        }
        return data
    }
}
