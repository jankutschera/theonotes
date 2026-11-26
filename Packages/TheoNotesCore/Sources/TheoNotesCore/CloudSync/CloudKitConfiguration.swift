// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Where the CloudKit container identifier comes from: the Info.plist key `THEONOTES_CloudKitContainer`, substituted from
/// `THEONOTES_CLOUDKIT_CONTAINER` in `config/release.env`. Empty, unsubstituted or malformed means "iCloud sync is not
/// available in this build". No other source file contains a container name.
public struct CloudKitConfiguration: Sendable, Equatable {
    public static let infoDictionaryKey = "THEONOTES_CloudKitContainer"
    public static let defaultZoneName = "TheoNotes"

    public let containerIdentifier: String
    public let zoneName: String
    /// The second record zone: `BlobPart` records only. `CKSyncEngine` never fetches it.
    public var blobZoneName: String { zoneName + "Blobs" }

    public init(containerIdentifier: String, zoneName: String = CloudKitConfiguration.defaultZoneName) {
        self.containerIdentifier = containerIdentifier; self.zoneName = zoneName
    }

    public static func fromBundle(_ bundle: Bundle) -> CloudKitConfiguration? {
        from(infoDictionary: bundle.infoDictionary ?? [:])
    }

    public static func from(infoDictionary: [String: Any]) -> CloudKitConfiguration? {
        guard let raw = infoDictionary[infoDictionaryKey] as? String, isValid(raw) else { return nil }
        return CloudKitConfiguration(containerIdentifier: raw)
    }

    /// `iCloud.` followed by at least one reverse-DNS character; no whitespace, no unsubstituted `$(...)`.
    static func isValid(_ value: String) -> Bool {
        let prefix = "iCloud."
        guard value.hasPrefix(prefix), value.utf8.count > prefix.utf8.count, value.utf8.count <= 255 else { return false }
        return value.utf8.dropFirst(prefix.utf8.count).allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 45
        }
    }
}
