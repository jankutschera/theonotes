// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Identity key for titles, tag paths and wiki-link targets: `NFC(fold(NFC(s)))` with Unicode
/// case folding (no locale) and diacritics kept. Never use SQLite `NOCASE` (ASCII-only).
public enum CanonicalKey {
    public static func make(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: nil)
            .precomposedStringWithCanonicalMapping
    }
}
