// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AuthenticationServices
import UIKit
import TheoNotesCore

/// The system browser owns passkey UI. Grant validation and device-key proof stay in the core
/// enrollment client; this adapter only returns the system's callback URL.
@MainActor final class MobileWebAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var anchor: UIWindow?
    private var activeID: UUID?

    func authenticate(at url: URL) async throws -> URL {
        try Task.checkCancellation()
        guard session == nil else { throw CocoaError(.userCancelled) }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw ASWebAuthenticationSessionError(.presentationContextNotProvided)
        }
        anchor = window
        let id = UUID()
        activeID = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let completion = WebAuthenticationCallback.makeHandler { [weak self] result in
                    self?.finish(result, id: id)
                }
                let session = ASWebAuthenticationSession(url: url, callback: .customScheme("baerchen"), completionHandler: completion)
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                if !session.start() { finish(.failure(ASWebAuthenticationSessionError(.presentationContextInvalid)), id: id) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor ?? UIWindow() }

    func cancel() {
        if let activeID { cancel(id: activeID) }
    }

    private func cancel(id: UUID) {
        guard activeID == id else { return }
        session?.cancel()
        finish(.failure(CancellationError()), id: id)
    }

    private func finish(_ result: Result<URL, any Error>, id: UUID) {
        guard activeID == id else { return }
        let pending = continuation
        continuation = nil; session = nil; anchor = nil; activeID = nil
        pending?.resume(with: result)
    }
}
