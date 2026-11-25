// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// The one folding both sides of a text search go through: what `note_search_content` stores and
/// what a query term is compared as. Case- and diacritic-insensitive with full case folding, so
/// `ß` matches `ss` (as in Bear: `strasse` finds `Straße`). A pure text → text function, so
/// migrations may call it.
public enum SearchText {
    public static func fold(_ s: String) -> String {
        if s.utf8.allSatisfy({ $0 < 0x80 }) { return s.lowercased() }
        return s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
