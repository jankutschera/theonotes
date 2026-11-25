// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Identity key for note titles and wiki-link targets (fix B1, ruling R38): whitespace runs
/// collapsed to one space and the ends trimmed, then `CanonicalKey`.
///
/// A title keeps its whitespace runs (`Big    Title`, Bear oracle), but a wiki link cannot say them:
/// the link parser collapses its target. Both sides therefore go through this one function, so
/// `[[Big    Title]]` and `[[Big Title]]` name a note titled either way. The one key for
/// `note.titleKey`, `wiki_link.targetKey`, the resolver and backlinks.
public enum TitleKey {
    public static func make(_ s: String) -> String {
        CanonicalKey.make(Chars.collapse(s))
    }
}
