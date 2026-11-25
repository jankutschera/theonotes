// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// View ▸ Zoom In / Zoom Out / Actual Size: one app-wide editor zoom (`SettingKey.editorZoom`),
/// applied as every editor web view's `pageZoom`. It scales the editor, not the shell.
enum EditorZoom {
    static let steps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
    static let actualSize = 1.0

    /// The step nearest to `z` (a stored value off the steps, or out of range, snaps).
    static func snap(_ z: Double) -> Double {
        guard z.isFinite else { return actualSize }
        return steps.min { abs($0 - z) < abs($1 - z) } ?? actualSize
    }

    /// The step after `z` (snapped first); the largest step stays.
    static func zoomIn(_ z: Double) -> Double {
        let current = snap(z)
        return steps.first { $0 > current + 1e-9 } ?? steps[steps.count - 1]
    }

    /// The step before `z` (snapped first); the smallest step stays.
    static func zoomOut(_ z: Double) -> Double {
        let current = snap(z)
        return steps.last { $0 < current - 1e-9 } ?? steps[0]
    }
}
