// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

#if os(macOS)
import CoreServices
import Foundation

/// Every file that enters `Attachments/` carries a quarantine record, so Gatekeeper still checks
/// an attached app, script or installer when someone opens it (the copy would otherwise lose the
/// attribute its download had). A file copied from a URL keeps its source's record; bytes (paste,
/// Bear and Apple Notes imports, data images) and sources without one get a fresh Theo Notes record.
/// Uses the documented resource value (`URLResourceKey.quarantinePropertiesKey`).
enum AttachmentQuarantine {
    static let agentName = "Theo Notes"

    /// The source's quarantine properties when it has them, otherwise a fresh record.
    static func properties(from source: URL?) -> [String: Any] {
        if let source, let properties = try? source.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties,
           !properties.isEmpty {
            return properties
        }
        return fresh()
    }

    static func fresh() -> [String: Any] {
        [
            kLSQuarantineAgentNameKey as String: agentName,
            kLSQuarantineAgentBundleIdentifierKey as String: "com.truebrewbirdie.baerchen",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineTimeStampKey as String: Date(),
        ]
    }

    /// Sets `properties` on the file at `path`; failures (a volume without extended attributes)
    /// are logged, the open guard in the app still applies.
    static func apply(_ properties: [String: Any], to path: String) {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.quarantineProperties = properties
        do {
            try url.setResourceValues(values)
        } catch {
            storeLogger.error("attachment quarantine not set: \(error)")
        }
    }

    /// A fresh record for a file that has none (copies, recovered and renamed files).
    static func ensure(_ path: String) {
        guard properties(of: path) == nil else { return }
        apply(fresh(), to: path)
    }

    static func properties(of path: String) -> [String: Any]? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
    }
}

#else
import Foundation

/// Gatekeeper quarantine metadata exists only on macOS. On iOS attachments remain
/// sandboxed data; the editor serves active formats as inert text and previews via Quick Look.
enum AttachmentQuarantine {
    static func properties(from source: URL?) -> [String: Any] { [:] }
    static func fresh() -> [String: Any] { [:] }
    static func apply(_ properties: [String: Any], to path: String) {}
    static func ensure(_ path: String) {}
    static func properties(of path: String) -> [String: Any]? { nil }
}
#endif
