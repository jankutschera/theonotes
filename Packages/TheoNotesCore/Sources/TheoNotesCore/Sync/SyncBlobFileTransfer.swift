// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Executes signed ciphertext requests. Implementations must refuse redirects and bound responses.
public protocol SyncBlobFileTransfer: Sendable {
    func upload(request: URLRequest, file: URL, id: String) async throws -> HTTPURLResponse
    func download(request: URLRequest, maximum: Int64, id: String) async throws -> (URL, HTTPURLResponse)
}
