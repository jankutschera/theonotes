// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// AuthenticationServices may invoke its completion on a background XPC queue.
/// The callback itself must be nonisolated: an inner MainActor task cannot prevent
/// a Swift 6 isolation trap at entry to a closure that inherited MainActor isolation.
public enum WebAuthenticationCallback {
    public nonisolated static func makeHandler(
        deliver: @escaping @MainActor @Sendable (Result<URL, any Error>) -> Void
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { callback, error in
            let result: Result<URL, any Error>
            if let error { result = .failure(error) }
            else if let callback { result = .success(callback) }
            else { result = .failure(CocoaError(.userCancelled)) }
            Task { @MainActor in deliver(result) }
        }
    }
}
