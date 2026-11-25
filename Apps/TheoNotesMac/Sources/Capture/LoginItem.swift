// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import ServiceManagement

@MainActor
protocol LoginItemControlling: AnyObject {
    var isEnabled: Bool { get }
    /// Registered, but the user still has to allow it in System Settings.
    var requiresApproval: Bool { get }
    func setEnabled(_ on: Bool) throws
    func openSystemSettings()
}

/// Open at login through the system's login item for the main app (no helper, no permission prompt).
@MainActor
final class SystemLoginItem: LoginItemControlling {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    func setEnabled(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
