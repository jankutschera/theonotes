// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// `attachments list|add|add-url|delete|save`. Check order (rulings M5-R45, M5-R51, M5-R59):
/// arguments (note, then `--filename` / `--url`, then the terminal checks), the library, the note,
/// the lock, then the attachment. State-changing commands print nothing on success.
enum AttachmentCommands {
    static let handlers: [[String]: CommandHandler] = [
        ["attachments", "list"]: list,
        ["attachments", "add"]: add,
        ["attachments", "add-url"]: addURL,
        ["attachments", "delete"]: delete,
        ["attachments", "save"]: save,
    ]

    /// Bytes of a stored attachment per write to stdout.
    private static let chunkSize = 1 << 20

    private static func service(_ env: CommandEnvironment) throws(AutomationError) -> AutomationService {
        AutomationService(library: try env.library(), context: env.context)
    }

    private static func selector(_ parsed: ParsedCommand) throws(AutomationError) -> NoteSelector {
        try NoteSelector.parse(id: parsed.positionals.first, title: parsed.value("--title"))
    }

    /// `--filename`, nil when absent or blank.
    private static func filename(_ parsed: ParsedCommand) -> String? {
        guard let value = parsed.value("--filename"),
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    private static func requiredFilename(_ parsed: ParsedCommand) throws(AutomationError) -> String {
        guard let name = filename(parsed) else {
            throw AutomationError(code: .usage, message: "--filename is required")
        }
        return name
    }

    // MARK: list

    private static func list(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try selector(parsed)
        let service = try service(env)
        // As in `show`: the note resolves first, then the fields, then the lock (M5-R51).
        var fields: [String] = []
        let files = try service.listAttachments(selector) { _ throws(AutomationError) in
            fields = try NoteFields.parse(parsed.fieldsArgument, spec: parsed.spec)
        }
        let rows = files.map { file in
            fields.map { $0 == "size" ? FieldValue.int(file.size) : FieldValue.string(file.filename) }
        }
        ReadCommands.writeRows(rows, fields: fields, format: parsed.format, emptyMessage: nil, env: env)
    }

    // MARK: add, add-url

    private static func add(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try selector(parsed)
        let name = try requiredFilename(parsed)
        guard !env.io.stdinIsTTY else {
            throw AutomationError(code: .usage, message: "Attachment data is read from stdin; pipe a file in")
        }
        // One byte past the limit is enough to know it is too big; the rest is never read.
        let limit = env.context.maxAttachmentBytes
        let data: Data
        do {
            data = try env.io.readStdin(upTo: limit + 1)
        } catch {
            throw AutomationError(code: .internal, message: "Standard input could not be read: \(error.localizedDescription)")
        }
        guard data.count <= limit else {
            throw AutomationError(code: .usage, message: AutomationService.tooLarge(limit))
        }
        guard !data.isEmpty else { throw AutomationError(code: .usage, message: "Attachment data is empty") }
        _ = try service(env).addAttachment(
            selector, data: data, filename: name, preservingModifiedDate: parsed.flag("--no-update-modified"))
    }

    private static func addURL(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try selector(parsed)
        guard let raw = parsed.value("--url"), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError(code: .usage, message: "--url is required")
        }
        let url = try URLFetchPolicy.parse(raw)
        let name = filename(parsed)
        let preserving = parsed.flag("--no-update-modified")
        let service = try service(env)
        let outcome: Result<String, AutomationError> = CLIBlocking.run {
            do throws(AutomationError) {
                let (_, stored) = try await service.addAttachment(
                    selector, url: url, filename: name, preservingModifiedDate: preserving)
                return .success(stored)
            } catch {
                return .failure(error)
            }
        }
        _ = try outcome.get()
    }

    // MARK: delete

    private static func delete(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try selector(parsed)
        let name = try requiredFilename(parsed)
        _ = try service(env).deleteAttachment(
            selector, filename: name, preservingModifiedDate: parsed.flag("--no-update-modified"))
    }

    // MARK: save

    /// The raw bytes of the file on stdout (ruling M5-R33), read and written one chunk at a time.
    private static func save(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let selector = try selector(parsed)
        let name = try requiredFilename(parsed)
        guard !env.io.stdoutIsTTY else {
            throw AutomationError(
                code: .usage, message: "Refusing to write binary data to a terminal; redirect stdout to a file")
        }
        let file = try service(env).attachmentFile(selector, filename: name)
        let handle = try openRegularFile(file, named: name)
        defer { try? handle.close() }
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw AutomationError(
                    code: .internal, message: "The attachment could not be read: \(error.localizedDescription)")
            }
            if chunk.isEmpty { break }
            do {
                try env.io.writeStreaming(chunk)
            } catch {
                throw AutomationError(
                    code: .internal, message: "The attachment could not be written: \(error.localizedDescription)")
            }
        }
    }

    /// Opens `url` for reading only if it is a regular file, without following a symlink: the file
    /// was checked a moment ago, but it may have been swapped since. The type is read from the open
    /// descriptor, so a FIFO or device put in its place is refused rather than read.
    static func openRegularFile(_ url: URL, named name: String) throws(AutomationError) -> FileHandle {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        var info = stat()
        guard descriptor >= 0 else {
            throw AutomationError(code: .attachmentNotFound, message: "Attachment not found: \(name)")
        }
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw AutomationError(code: .attachmentNotFound, message: "Attachment not found: \(name)")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

/// Runs async work to completion from synchronous code and waits on the calling thread. The work
/// runs on `OffPoolExecutor`, so a caller on a cooperative-pool thread (a synchronous test) cannot
/// starve it: it never needs the thread it blocks.
private enum CLIBlocking {
    private final class Box<T: Sendable>: @unchecked Sendable {
        var value: T?
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached(executorPreference: OffPoolExecutor.shared) {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }
}
