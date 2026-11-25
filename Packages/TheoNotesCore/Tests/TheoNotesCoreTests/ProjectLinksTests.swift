// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct ProjectLinksTests {
    @Test func theSourceOfferNamesTheLicenceAndThePublicHTTPSRepository() {
        #expect(ProjectLinks.sourceRepository.absoluteString == "https://github.com/jankutschera/theonotes")
        #expect(ProjectLinks.sourceOffer.contains("GNU General Public License v3"))
        #expect(ProjectLinks.sourceOffer.hasSuffix(ProjectLinks.sourceRepository.absoluteString))
    }
}
