// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

/// The receipt `cat` hands out and `overwrite --base` checks: the first 7 lowercase hex digits
/// of the SHA-256 of the UTF-8 bytes (observed: `hashAlgorithm` `sha256-hex-prefix`, length 7).
enum ContentHash {
    static func of(_ s: Substring.UTF8View) -> String { hex(SHA256.hash(data: Data(s))) }

    static func of(_ s: String) -> String { hex(SHA256.hash(data: Data(s.utf8))) }

    private static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for byte in digest.prefix(4) {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out.prefix(7), as: UTF8.self)
    }
}
