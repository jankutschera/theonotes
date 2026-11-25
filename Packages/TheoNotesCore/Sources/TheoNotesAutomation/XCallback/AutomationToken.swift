// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Security

/// The token that lets an x-callback caller read data back (`tags`, note lists, the selected
/// note). Stored in the `setting` table as `automationToken`; "" means none yet.
public enum AutomationToken {
    /// The stored token, generated and saved first when there is none.
    public static func ensure(_ s: Settings) throws -> String {
        let stored = try s.value(.automationToken)
        if !stored.isEmpty { return stored }
        return try regenerate(s)
    }

    /// A new token replacing the stored one; the old one stops working at once.
    public static func regenerate(_ s: Settings) throws -> String {
        let token = try generate()
        try s.set(.automationToken, to: token)
        return token
    }

    /// Constant-time comparison over the longer length. An empty stored token never matches. The
    /// accumulator is a full `UInt`, so a length difference (a multiple of 256, say) cannot wrap
    /// to zero.
    public static func matches(_ given: String?, _ stored: String) -> Bool {
        guard let given, !stored.isEmpty else { return false }
        let a = Array(given.utf8)
        let b = Array(stored.utf8)
        var difference = UInt(a.count) ^ UInt(b.count)
        for i in 0..<max(a.count, b.count) {
            difference |= UInt((i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0))
        }
        return difference == 0
    }

    struct GenerationError: Error, CustomStringConvertible {
        var status: Int32
        var description: String { "Could not generate a random token (status \(status))" }
    }

    /// Nine random bytes as three groups of six uppercase hex digits.
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 9)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw GenerationError(status: status) }
        let digits = Array("0123456789ABCDEF")
        let hex = bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] }
        return stride(from: 0, to: hex.count, by: 6).map { String(hex[$0..<$0 + 6]) }.joined(separator: "-")
    }
}
