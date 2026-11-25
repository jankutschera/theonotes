// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Synchronization
import UIKit

/// URLSession owns the network tasks; the journal owns their identity and completed results.
/// No account keys or plaintext enter this directory or task descriptions.
final class MobileBlobFiles: NSObject, SyncBlobFileTransfer, URLSessionDownloadDelegate, URLSessionDataDelegate, @unchecked Sendable {
    @MainActor static func cancelAll() {
        guard let value = retained else { return }
        value.cancel()
        retained = nil
    }
    @MainActor private static var retained: MobileBlobFiles?
    @MainActor static func connect(directory: URL, identity: String? = nil) throws -> MobileBlobFiles? {
        let identityFile = directory.appendingPathComponent("identity")
        let saved = try? String(contentsOf: identityFile, encoding: .utf8)
        guard let identity = identity ?? saved else { return nil }
        if let retained, retained.prefix == identity { return retained }
        if retained != nil { cancelAll() }
        if saved != nil && saved != identity { try? FileManager.default.removeItem(at: directory) }
        let value = try MobileBlobFiles(directory: directory, identity: identity)
        try identity.write(to: identityFile, atomically: true, encoding: .utf8)
        retained = value
        return value
    }
    static let identifier = MobileIdentity.encryptedBlobsSessionIdentifier
    @MainActor private static var backgroundCompletion: (() -> Void)?
    @MainActor private static var finishedEvents = false
    @MainActor static func handleEvents(_ completion: @escaping () -> Void) {
        if finishedEvents { finishedEvents = false; completion() }
        else { backgroundCompletion = completion }
    }
    private struct Entry: Codable {
        var id: String
        var maximum: Int64
        var upload: Bool
        var status: Int?
        var headers: [String: String]?
        var error: Bool = false
        var received: Int64 = 0
    }
    private let directory: URL
    private let entries: Mutex<[String: Entry]>
    private let session = Mutex<URLSession?>(nil)
    private let prefix: String
    private let taskLookup: @Sendable (URLSession) async -> [URLSessionTask]

    init(directory: URL, identity: String, configuration: URLSessionConfiguration? = nil,
         taskLookup: @escaping @Sendable (URLSession) async -> [URLSessionTask] = { await $0.allTasks }) throws {
        self.directory = directory; prefix = identity; self.taskLookup = taskLookup
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var location = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try location.setResourceValues(values)
        let journal = directory.appendingPathComponent("journal.json")
        let saved = (try? Data(contentsOf: journal)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = Mutex(saved)
        // Copies handed to a dead process have no owner; durable task files remain referenced.
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "cipher" && saved[file.deletingPathExtension().lastPathComponent] == nil {
            try? FileManager.default.removeItem(at: file)
        }
        super.init()
        let config = configuration ?? URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true; config.isDiscretionary = false
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 24 * 60 * 60
        session.withLock { $0 = URLSession(configuration: config, delegate: self, delegateQueue: nil) }
        Task {
            for task in await client.allTasks {
                guard let id = task.taskDescription, entries.withLock({ $0[id] != nil }) else { task.cancel(); continue }
                if task.state == .suspended { task.resume() }
            }
        }
    }
    func cancel() {
        entries.withLock { $0.removeAll() }
        client.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
    private var client: URLSession { session.withLock { $0! } }
    private func key(_ id: String, upload: Bool) -> String {
        SyncWire.hash(Data((prefix + (upload ? ":put:" : ":get:") + id).utf8))
    }
    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".cipher") }
    private func save(_ values: [String: Entry]) throws {
        try JSONEncoder().encode(values).write(to: directory.appendingPathComponent("journal.json"), options: .atomic)
    }
    func upload(request: URLRequest, file source: URL, id: String) async throws -> HTTPURLResponse {
        let key = key(id, upload: true)
        try await start(request: request, source: source, maximum: 65_536, key: key)
        let response = try await result(key: key, request: request)
        discard(key)
        return response
    }
    func download(request: URLRequest, maximum: Int64, id: String) async throws -> (URL, HTTPURLResponse) {
        let key = key(id, upload: false)
        try await start(request: request, source: nil, maximum: maximum, key: key)
        let response = try await result(key: key, request: request)
        // The core takes ownership of its temporary file. Preserve the journal result for retry.
        let copy = directory.appendingPathComponent(UUID().uuidString + ".cipher")
        try FileManager.default.copyItem(at: file(key), to: copy)
        discard(key)
        return (copy, response)
    }
    private func discard(_ key: String) {
        entries.withLock { values in
            values.removeValue(forKey: key); try? save(values)
            try? FileManager.default.removeItem(at: file(key))
        }
    }
    private func start(request: URLRequest, source: URL?, maximum: Int64, key: String) async throws {
        try Task.checkCancellation()
        // A durable completed transfer needs no system task lookup. Background-session
        // enumeration can be delayed independently of its already-delivered completion.
        let completed = entries.withLock { values in
            guard let entry = values[key], let status = entry.status else { return false }
            return (200..<300).contains(status) && !entry.error &&
                (entry.upload || FileManager.default.fileExists(atPath: file(key).path))
        }
        if completed { return }
        let tasks = await taskLookup(client)
        try Task.checkCancellation()
        try entries.withLock { values in
            if let entry = values[key], let status = entry.status, (200..<300).contains(status), !entry.error,
               entry.upload || FileManager.default.fileExists(atPath: file(key).path) { return }
            if let task = tasks.first(where: { $0.taskDescription == key }) {
                if task.state == .suspended { task.resume() }
                return
            }
            values[key] = Entry(id: key, maximum: maximum, upload: source != nil)
            if let source {
                try? FileManager.default.removeItem(at: file(key))
                try FileManager.default.copyItem(at: source, to: file(key))
            }
            // Persist before resume so a process death never leaves an unidentifiable task.
            try save(values)
            let task: URLSessionTask
            if source != nil { task = client.uploadTask(with: request, fromFile: file(key)) }
            else { task = client.downloadTask(with: request) }
            task.taskDescription = key; task.resume()
        }
    }
    private func result(key: String, request: URLRequest) async throws -> HTTPURLResponse {
        while true {
            try Task.checkCancellation() // Detach the foreground waiter; retain system work.
            let entry = entries.withLock { $0[key] }
            guard let entry, !entry.error else { throw URLError(.networkConnectionLost) }
            if let status = entry.status {
                guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: entry.headers) else { throw SyncHTTPError.invalidResponse }
                return response
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        entries.withLock { values in
            guard var entry = values[key] else { return }
            do {
                let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= entry.maximum else { throw SyncHTTPError.invalidResponse }
                try? FileManager.default.removeItem(at: file(key))
                try FileManager.default.moveItem(at: location, to: file(key))
            } catch { entry.error = true; values[key] = entry; downloadTask.cancel() }
            try? save(values)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription, let maximum = entries.withLock({ $0[key]?.maximum }) else { downloadTask.cancel(); return }
        if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = entries.withLock { values in
            guard let key = dataTask.taskDescription, var entry = values[key] else { return true }
            entry.received += Int64(data.count); values[key] = entry
            return entry.received > entry.maximum
        }
        if exceeded { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let key = task.taskDescription else { return }
        entries.withLock { values in
            guard var entry = values[key] else { return }
            entry.error = entry.error || error != nil
            if let response = task.response as? HTTPURLResponse {
                entry.status = response.statusCode
                entry.headers = response.allHeaderFields.reduce(into: [:]) { result, pair in
                    if let name = pair.key as? String, let value = pair.value as? String { result[name] = value }
                }
                // Failed signed requests must be re-signed by the authenticated core on retry.

            } else { entry.error = true }
            values[key] = entry; try? save(values)
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            if let completion = Self.backgroundCompletion {
                Self.backgroundCompletion = nil; completion()
            } else { Self.finishedEvents = true }
        }
    }
}

final class MobileBackgroundSessionDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        MobileSceneActivityInbox.shared.receiveCold(options.userActivities,
            sceneSessionID: connectingSceneSession.persistentIdentifier)
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = MobileQuickActionSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(MobileQuickActions.receive(type: shortcutItem.type))
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == MobileBlobFiles.identifier else { completionHandler(); return }
        MobileBlobFiles.handleEvents(completionHandler)
    }
}
