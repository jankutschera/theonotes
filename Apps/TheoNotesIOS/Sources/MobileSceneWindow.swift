// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Observation
import SwiftUI
import UIKit

/// A weak native window identity. Scene privacy must never guess UIApplication's key window.
@MainActor final class MobileSceneWindowReference {
    weak var window: UIWindow?
}

struct MobileSceneWindowProbe: UIViewRepresentable {
    let reference: MobileSceneWindowReference
    var onWindowAttached: @MainActor (UIWindow) -> Void = { _ in }
    func makeUIView(context: Context) -> UIView { Probe(reference: reference, onWindowAttached: onWindowAttached) }
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let probe = uiView as? Probe else { return }
        probe.onWindowAttached = onWindowAttached
        if let window = probe.window { onWindowAttached(window) }
    }
    @MainActor private final class Probe: UIView {
        private let reference: MobileSceneWindowReference
        var onWindowAttached: @MainActor (UIWindow) -> Void
        init(reference: MobileSceneWindowReference, onWindowAttached: @escaping @MainActor (UIWindow) -> Void) {
            self.reference = reference
            self.onWindowAttached = onWindowAttached
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            reference.window = window
            if let window { onWindowAttached(window) }
        }
    }
}

/// The shared library may restart every registered reader after a global operation. This
/// scene gate prevents that restart from admitting reads for an already-background window.
@MainActor @Observable final class MobileSceneReadGate { var allowed = false }
