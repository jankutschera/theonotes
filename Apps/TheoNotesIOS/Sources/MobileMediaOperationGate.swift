// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Observation

/// One UI-owned operation; every callback must carry the ID returned by begin().
@MainActor @Observable final class MobileMediaOperationGate {
    private(set) var currentID: UUID?

    func begin() -> UUID? {
        guard currentID == nil else { return nil }
        let id = UUID()
        currentID = id
        return id
    }

    func isCurrent(_ id: UUID) -> Bool { currentID == id }

    @discardableResult func finish(_ id: UUID) -> Bool {
        guard isCurrent(id) else { return false }
        currentID = nil
        return true
    }

    /// Lifecycle reset only; delayed completion/dismissal callbacks must use finish(theirID).
    func invalidate() { currentID = nil }
}
