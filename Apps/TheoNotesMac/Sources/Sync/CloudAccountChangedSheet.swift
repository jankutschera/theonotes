// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI

/// CK-R10: this Mac is signed in to a different iCloud account than the one the library syncs with. Nothing is sent to the new
/// account unless the person says so; the default (Return) keeps the library offline.
struct CloudAccountChangedSheet: View {
    let controller: CloudSyncController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(CloudSyncStrings.accountChangedTitle, systemImage: "person.crop.circle.badge.exclamationmark").font(.headline)
            Text(CloudSyncStrings.accountChangedMessage).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Button(CloudSyncStrings.keepOffline) { Task { await controller.keepOffline() } }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("cloud-account-keep-offline")
                Text(CloudSyncStrings.keepOfflineDetail).font(.footnote).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Button(CloudSyncStrings.syncWithNewAccount) { Task { await controller.syncWithNewAccount() } }
                    .accessibilityIdentifier("cloud-account-sync-new")
                Text(CloudSyncStrings.syncWithNewAccountDetail).font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(CloudSyncStrings.accountChangedContinue) { controller.showsAccountChangedSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .disabled(controller.isWorking)
    }
}
