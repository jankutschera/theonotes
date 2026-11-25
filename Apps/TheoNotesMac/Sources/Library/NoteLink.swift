// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// The link Copy Link puts on the pasteboard: the app's own x-callback `open-note` URL, built like
/// the one on iPhone and iPad (the dev identity has its own scheme).
enum NoteLink {
    static func url(id: String, identity: AppIdentity = .current) -> URL {
        var components = URLComponents()
        components.scheme = identity.urlSchemes[0]
        components.host = "x-callback-url"
        components.path = "/open-note"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url!
    }
}
