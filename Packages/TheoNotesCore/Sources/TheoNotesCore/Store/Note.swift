// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

public enum NoteLocation: String, Codable, Sendable, DatabaseValueConvertible {
    case notes, archive, trash
}

public struct Note: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "note"

    public var id: String
    public var text: String
    public var title: String
    public var titleKey: String
    public var subtitle: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var location: NoteLocation
    public var trashedAt: Date?
    public var archivedAt: Date?
    public var isPinnedGlobal: Bool
    public var isReadOnly: Bool
    public var isLocked: Bool
    public var encryptedPayload: Data?
    public var revision: Int
    public var deletedAt: Date?

    public init(
        id: String,
        text: String,
        title: String,
        titleKey: String,
        subtitle: String = "",
        createdAt: Date,
        modifiedAt: Date,
        location: NoteLocation = .notes,
        trashedAt: Date? = nil,
        archivedAt: Date? = nil,
        isPinnedGlobal: Bool = false,
        isReadOnly: Bool = false,
        isLocked: Bool = false,
        encryptedPayload: Data? = nil,
        revision: Int = 1,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.title = title
        self.titleKey = titleKey
        self.subtitle = subtitle
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.location = location
        self.trashedAt = trashedAt
        self.archivedAt = archivedAt
        self.isPinnedGlobal = isPinnedGlobal
        self.isReadOnly = isReadOnly
        self.isLocked = isLocked
        self.encryptedPayload = encryptedPayload
        self.revision = revision
        self.deletedAt = deletedAt
    }
}

enum UUIDv7 {
    /// Lowercase hyphenated UUIDv7: 48-bit ms timestamp, version 7, variant 10, random rest.
    static func make(now: Date = .now) -> String {
        let ms = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 {
            bytes[i] = UInt8((ms >> UInt64(8 * (5 - i))) & 0xff)
        }
        for i in 6..<16 {
            bytes[i] = UInt8.random(in: 0...255)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        return [
            hex[0..<4].joined(), hex[4..<6].joined(), hex[6..<8].joined(),
            hex[8..<10].joined(), hex[10..<16].joined(),
        ].joined(separator: "-")
    }
}
