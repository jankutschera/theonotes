// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// The public source of the apps, offered as the GPL-3.0 requires for corresponding source. The About window on
/// the Mac and Settings on iPhone and iPad show `sourceOffer`. The repository goes public before the first build
/// that carries this line ships (1.1.1).
public enum ProjectLinks {
    public static let sourceRepository = URL(string: "https://github.com/jankutschera/theonotes")!
    public static let sourceOffer = "Free software under the GNU General Public License v3. Source code: "
        + sourceRepository.absoluteString
}
