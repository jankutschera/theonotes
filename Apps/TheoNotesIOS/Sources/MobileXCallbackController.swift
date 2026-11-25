// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesAutomation
import TheoNotesCore
import Foundation
import Security
import UIKit

struct MobileCallbackNavigation: Equatable {
    let id = UUID()
    let noteID: String
    var header: String?
    var find: String?
    var edit: Bool
}

@MainActor enum MobileAutomationToken {
    static func credentialAccount(_ paths: AppPaths) -> String {
        if paths.root == AppPaths.production.root { return "mobile.production.v1" }
        if let id = try? SyncRecoveryLibrary.identity(paths: paths) { return "mobile.recovery." + id }
        return "mobile.test." + SyncWire.hash(Data(paths.root.path.utf8))
    }
    private static func query(_ paths: AppPaths) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: MobileIdentity.automationKeychainService,
         kSecAttrAccount as String: credentialAccount(paths), kSecAttrSynchronizable as String: false]
    }
    static func load(_ paths: AppPaths) throws -> String? {
        var query = query(paths); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = value as? Data, let token = String(data: bytes, encoding: .utf8) else { throw CocoaError(.fileReadNoPermission) }
        return token
    }
    static func revoke(_ paths: AppPaths) { SecItemDelete(query(paths) as CFDictionary) }
    @discardableResult static func generate(_ paths: AppPaths) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(paths) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var values = query(paths); attributes.forEach { values[$0.key] = $0.value }
            status = SecItemAdd(values as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
        return token
    }
}

@MainActor final class MobileXCallbackController {
    private weak var library: MobileLibrary?
    private var running = false
    private var operation: Task<MobileXCallbackResult, any Error>?
    /// Deterministic seam after accepted execution, before its UI delivery.
    var beforeResultDeliveryForTesting: (@MainActor () async throws -> Void)?
    private let openURL: (URL) -> Void
    private let fetcher: any URLFetcher
    init(library: MobileLibrary, openURL: @escaping (URL) -> Void = { UIApplication.shared.open($0) }, fetcher: any URLFetcher = HTTPSFetcher()) {
        self.library = library; self.openURL = openURL; self.fetcher = fetcher
    }
    func handle(_ url: URL) async {
        guard let library else { return }
        let request: MobileXCallbackRequest
        do { request = try MobileXCallbackRequest(url) }
        catch { library.errorMessage = "This automation URL is invalid."; return }
        var callbackSent = false
        do {
            guard !running, !library.isClosed, !library.isClosing, !library.libraryOperationBusy, !library.sceneOperationPending, !library.appLocked else { throw MobileXCallbackFailure.locked }
            running = true; defer { running = false }
            let token = try MobileAutomationToken.load(library.paths)
            _ = try MobileXCallbackDispatcher.authorize(request, token: token)
            try library.flush()
            let clipboard = request.yes("clipboard") ? UIPasteboard.general.string : nil
            var background: UIBackgroundTaskIdentifier = .invalid
            if request.action == "grab-url" {
                _ = try MobileXCallbackDispatcher.captureURL(request)
                background = UIApplication.shared.beginBackgroundTask(withName: "Finish captured webpage") { [weak self] in
                    Task { @MainActor in self?.operation?.cancel() }
                }
            }
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            if request.action == "grab-url", request.parameters["wait"] == "no", let callback = request.callback(request.success, values: [:]) {
                openURL(callback); callbackSent = true
            }
            let originalWorkspace = library.workspace
            let generation = library.libraryGeneration
            let dispatcher = MobileXCallbackDispatcher(database: library.database, paths: library.paths, store: library.store, fetcher: fetcher,
                canAccess: { [weak library] in library.map {
                    !$0.appLocked && !$0.isClosed && !$0.isClosing && !$0.libraryOperationBusy &&
                    !$0.sceneOperationPending && $0.libraryGeneration == generation
                } ?? false })
            let work = Task { try await dispatcher.execute(request, token: token, selectedID: library.selectedID, clipboard: clipboard) }
            operation = work
            defer { operation = nil }
            let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try await beforeResultDeliveryForTesting?()
            guard !library.appLocked, !library.isClosed, !library.isClosing else { throw MobileXCallbackFailure.locked }
            // Execution already succeeded: retain its callback, but never replay old UI into a restored library.
            if !library.libraryOperationBusy, !library.sceneOperationPending, library.libraryGeneration == generation {
                do {
                    try library.refreshSessions()
                    if let rewrite = result.tagRewrite { library.tagUndo = rewrite }
                    if let from = result.renamedTagFrom, let to = result.renamedTagTo {
                        if let workspace = originalWorkspace, Workspace(path: from).includes(tagPath: workspace.path) {
                            let suffix = workspace.path.split(separator: "/").dropFirst(from.split(separator: "/").count)
                            library.workspace = Workspace(path: ([to] + suffix.map(String.init)).joined(separator: "/"))
                        }
                        library.scope = .tag(to); library.query = ""
                    }
                    if let deleted = result.deletedTag {
                        if let workspace = originalWorkspace, Workspace(path: deleted).includes(tagPath: workspace.path) { library.workspace = nil }
                        library.scope = .notes; library.query = ""
                    }
                    if result.changesWorkspace { try library.enterWorkspace(result.workspace) }
                    if let scope = result.scope {
                        if library.workspace != nil { try library.enterWorkspace(nil) }
                        library.scope = scope; library.selectedID = nil
                    }
                    if let query = result.query { library.query = query }
                    if let id = result.noteID {
                        try library.reveal(id)
                        library.pendingCallbackNavigation = MobileCallbackNavigation(noteID: id, header: result.header, find: result.find, edit: result.edit)
                    }
                } catch {
                    let saved = ["create", "grab-url", "add-text", "add-file", "rename-tag", "delete-tag", "trash", "archive"].contains(request.action)
                        || (request.action == "open-note" && request.yes("pin"))
                    guard saved else { throw error }
                    // Retrying a successful write would duplicate it; only its presentation failed.
                    library.errorMessage = "Automation was saved, but its window could not be updated: " + error.localizedDescription
                }
            }
            if !callbackSent, let callback = request.callback(request.success, values: result.values) { openURL(callback) }
            // The answer is handed back: a later identical request is a new one (REL-R93).
            if let receipt = result.receipt { XCallbackReceipts(database: library.database).settle(receipt) }
        } catch {
            if !callbackSent, let callback = request.callback(request.failure, values: ["errorCode": "1", "errorMessage": String(describing: error)]) { openURL(callback) }
            else { library.errorMessage = "Automation could not complete: " + error.localizedDescription }
        }
    }
}
