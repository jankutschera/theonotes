// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Observation
import TheoNotesCore
import QuickLook
import SwiftUI
import UIKit

/// Header-only routing hint after an explicit guarded attachment read. It never decodes
/// pixels or drawing archives; actual crop/sketch decoders still validate the full input.
enum MobileAttachmentImagePresentation {
    struct Inspection: Sendable { let isRaster: Bool; let hasSketchMetadata: Bool }
    static func inspect(_ data: Data) -> Inspection {
        let head = Array(data.prefix(12))
        let png = head.count >= 8 && Array(head.prefix(8)) == [137,80,78,71,13,10,26,10]
        let jpeg = head.count >= 3 && Array(head.prefix(3)) == [255,216,255]
        let gif = data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8))
        let bmp = data.starts(with: Data("BM".utf8))
        let tiff = data.starts(with: Data([73,73,42,0])) || data.starts(with: Data([77,77,0,42]))
        let webp = head.count == 12 && String(bytes: head.prefix(4), encoding: .ascii) == "RIFF" && String(bytes: head.suffix(4), encoding: .ascii) == "WEBP"
        let heif = head.count == 12 && String(bytes: head[4..<8], encoding: .ascii) == "ftyp" && ["heic","heix","hevc","hevx","mif1","msf1","avif","avis"].contains(String(bytes: head[8..<12], encoding: .ascii) ?? "")
        var marker = false, offset = 8
        if png {
            while offset <= data.count - 8 {
                let i = data.startIndex + offset
                let length = Int(data[i]) << 24 | Int(data[i+1]) << 16 | Int(data[i+2]) << 8 | Int(data[i+3])
                if data[(i+4)..<(i+8)].elementsEqual("thND".utf8) { marker = true; break }
                guard offset <= data.count - 12, length <= data.count - offset - 12 else { break }
                offset += length + 12
            }
        }
        return Inspection(isRaster: png || jpeg || gif || bmp || tiff || webp || heif, hasSketchMetadata: marker)
    }
}

@MainActor enum MobileSketchLifecyclePolicy {
    static func shouldSuspend(phase: ScenePhase, appLocked: Bool) -> Bool { appLocked || phase == .background }
    static func deferredAfterProgrammaticSuspend(wasDeferred: Bool, hadPrompt: Bool) -> Bool { wasDeferred && !hadPrompt }
}

/// Reads provider files through one descriptor, with a hard aggregate allocation bound.
/// No bytes are stored in the library until the editor revalidates its origin afterward.
enum MobileAttachmentFileReader {
    static func read(_ urls: [URL], maximumBytes: Int = 250 * 1024 * 1024,
                     afterOpen: (@Sendable (URL) throws -> Void)? = nil) throws -> [ImportedAttachment] {
        var remaining = maximumBytes
        return try urls.map { url in
            try Task.checkCancellation()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else { throw CocoaError(.fileReadUnsupportedScheme) }
            guard before.st_size <= Int64(remaining) else { throw CocoaError(.fileReadTooLarge) }
            try afterOpen?(url)
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, remaining - data.count + 1)) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if count == 0 { break }
                guard count <= remaining - data.count else { throw CocoaError(.fileReadTooLarge) }
                data.append(contentsOf: buffer.prefix(count))
            }
            var after = stat(), path = stat()
            guard fstat(fd, &after) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard lstat(url.path, &path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard sameFile(before, after), sameFile(after, path), data.count == before.st_size else {
                throw CocoaError(.fileReadUnknown)
            }
            remaining -= data.count
            return ImportedAttachment(filename: url.lastPathComponent, data: data, source: url)
        }
    }

    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_mode & S_IFMT == S_IFREG && b.st_mode & S_IFMT == S_IFREG &&
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}

struct MobileAttachmentTarget: Identifiable, Equatable {
    let id = UUID()
    let noteID: String
    let filename: String
    let from: Int
    let to: Int
    let source: String
}

enum MobileAttachmentError: LocalizedError, Equatable {
    case stale, unavailable, name, width, notApplied
    var errorDescription: String? {
        switch self {
        case .stale: "The note or attachment changed. Start this action again."
        case .unavailable: "This attachment is no longer available for this action."
        case .name: "Enter a single filename and keep its original file extension."
        case .width: "Choose an image width between 16 and 4096 points."
        case .notApplied: "The files were saved, but insertion could not be confirmed. Keep this note open until the editor finishes saving."
        }
    }
}

extension MobileLibrary {
    /// Rename by retaining the original bytes for editor undo, including encrypted notes.
    /// Private files are streamed through the existing encrypted attachment writer.
    func mobileRenameAttachment(_ filename: String, to name: String, noteID: String) throws -> String {
        guard let note = try store.note(id: noteID), canRead(note), !note.isReadOnly, note.location == .notes else {
            throw MobileAttachmentError.unavailable
        }
        if !note.isLocked { return try AttachmentStore(paths: paths, database: database).rename(filename, to: name, in: noteID) }
        guard let access = privateAccess, let source = try attachmentURL(filename, noteID: noteID) else {
            throw MobileAttachmentError.unavailable
        }
        let directory = paths.root.appendingPathComponent("UnlockedPreviews/Rename/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        defer { try? FileManager.default.removeItem(at: directory) }
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let staged = directory.appendingPathComponent(name)
        do { try FileManager.default.linkItem(at: source, to: staged) }
        catch { try FileManager.default.copyItem(at: source, to: staged) }
        let renamed = try access.addAttachment(fileAt: staged, to: noteID)
        try refreshSessions() // The encrypted manifest bumps the store revision without changing text.
        return renamed
    }
}

/// Actual sheet lifetime, independent of its item binding becoming nil during dismissal.
@MainActor @Observable final class MobileCaptureModalGate {
    private var leases = Set<UUID>()
    var isPresented: Bool { !leases.isEmpty }
    func presented(_ id: UUID) { leases.insert(id) }
    func dismissed(_ id: UUID) { leases.remove(id) }
}

/// Filter membership is not an access decision: inspect the authoritative stored note.
struct MobileAttachmentDraftAccessState: Equatable {
    private let readable: Bool
    private let editable: Bool
    private let locked: Bool?
    init(note: Note?, canRead: Bool) {
        readable = note.map { canRead && $0.deletedAt == nil } ?? false
        editable = note.map { !$0.isReadOnly && $0.location == .notes } ?? false
        locked = note?.isLocked
    }
    func permitsDraft(expectedLocked: Bool, requiresEditable: Bool = true) -> Bool {
        readable && (!requiresEditable || editable) && locked == expectedLocked
    }
}

enum MobileAttachmentEditIntent: Equatable { case tap, sketch, crop }

/// A reserved menu-to-editor handoff remains busy until the real editor sheet dismisses.
@MainActor @Observable final class MobileAttachmentEditLease {
    let id: UUID
    private let gate: MobileMediaOperationGate
    private(set) var isInvalidated = false
    private(set) var isPresented = false
    init(gate: MobileMediaOperationGate, id: UUID) { self.gate = gate; self.id = id }
    var canContinue: Bool { !isInvalidated && gate.isCurrent(id) }
    @discardableResult func present() -> Bool {
        guard canContinue, !isPresented else { return false }
        isPresented = true; return true
    }
    func cancel() {
        isInvalidated = true
        if !isPresented { gate.finish(id) }
    }
    @discardableResult func didDismiss() -> Bool {
        guard isPresented else { return false }
        isPresented = false; cancel(); return true
    }
}

extension View {
    func mobileAttachmentActions(editor: MobileEditor,
        onEdit: @escaping (MobileAttachmentTarget, MobileAttachmentEditIntent) -> Void = { _, _ in },
        onPresented: @escaping (UUID) -> Void = { _ in },
        onDismissed: @escaping (UUID) -> Void = { _ in }) -> some View {
        modifier(MobileAttachmentActionsModifier(editor: editor, onEdit: onEdit, onPresented: onPresented, onDismissed: onDismissed))
    }
    func mobileQuickLookPreview(_ item: Binding<URL?>,
        onPresented: @escaping (UUID) -> Void = { _ in },
        onDismissed: @escaping (UUID) -> Void = { _ in }) -> some View {
        modifier(MobileQuickLookModifier(item: item, onPresented: onPresented, onDismissed: onDismissed))
    }
}

private struct MobileAttachmentActionsModifier: ViewModifier {
    @Bindable var editor: MobileEditor
    let onEdit: (MobileAttachmentTarget, MobileAttachmentEditIntent) -> Void
    let onPresented: (UUID) -> Void
    let onDismissed: (UUID) -> Void
    @State private var leaseID = UUID()
    func body(content: Content) -> some View {
        content.sheet(item: $editor.attachmentTarget, onDismiss: {
            onDismissed(leaseID); leaseID = UUID()
        }) { target in
            MobileAttachmentActions(editor: editor, target: target, onEdit: onEdit).onAppear { onPresented(leaseID) }
        }
    }
}

/// A real sheet hook replaces SwiftUI quickLookPreview's missing onDismiss API.
/// QLPreviewController still provides the native preview; no delegate swizzling or timers.
private struct MobileQuickLookModifier: ViewModifier {
    @Binding var item: URL?
    let onPresented: (UUID) -> Void
    let onDismissed: (UUID) -> Void
    @State private var leaseID = UUID()
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }), onDismiss: {
            onDismissed(leaseID); leaseID = UUID()
        }) {
            if let item {
                VStack {
                    HStack { Spacer(); Button("Done") { self.item = nil } }.padding()
                    MobileAttachmentQuickLook(url: item)
                }.onAppear { onPresented(leaseID) }
            }
        }
    }
}

struct MobileAttachmentActions: View {
    @Bindable var editor: MobileEditor
    let target: MobileAttachmentTarget
    var onEdit: (MobileAttachmentTarget, MobileAttachmentEditIntent) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var rename = false
    @State private var name = ""
    @State private var remove = false
    @State private var resize = false
    @State private var width = ""
    @State private var error: String?
    @State private var preview: URL?
    @State private var share: MobileAttachmentShareItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Attachment").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }
            }.padding()
            Form {
                Section {
                    Text(target.filename).textSelection(.enabled)
                    Button("Quick Look", systemImage: "eye") { perform { preview = try editor.attachmentFile(target) } }.disabled(!editor.canExport)
                    Button("Save or Share File", systemImage: "square.and.arrow.up") {
                        perform { share = MobileAttachmentShareItem(url: try editor.attachmentFile(target)) }
                    }.disabled(!editor.canExport)
                }
                if editor.canEditAttachment(target) {
                    Section("Edit Attachment") {
                        Button("Rename", systemImage: "pencil") { name = target.filename; rename = true }
                        if AttachmentMarkdown.isImage(target.filename) || target.source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("![") {
                            Button("Edit Sketch", systemImage: "pencil.tip") { onEdit(target, .sketch) }
                            Button("Crop Image", systemImage: "crop") { onEdit(target, .crop) }
                            Button("Resize Image", systemImage: "arrow.up.left.and.arrow.down.right") { resize = true }
                            TextField("Width in points", text: $width).keyboardType(.numberPad)
                                .accessibilityIdentifier("attachment-image-width")
                            Button("Apply Width") { perform { try editor.resizeAttachment(target, width: Int(width)); dismiss() } }
                                .disabled(Int(width) == nil)
                        }
                        if (target.filename as NSString).pathExtension.lowercased() == "pdf" {
                            let shown = AttachmentMarkdown.metadata(target.source)["preview"] != "false"
                            Button(shown ? "Hide PDF Preview" : "Show PDF Preview") {
                                perform { try editor.setAttachmentPreview(target, shown: !shown); dismiss() }
                            }
                        }
                        Button("Remove from Note", systemImage: "trash", role: .destructive) { remove = true }
                    }
                } else {
                    Section { Text(editor.canExport ? "This note is read-only. You can preview or save the file." : "This note is read-only. Protected attachments cannot be exported.").foregroundStyle(.secondary) }
                }
            }
            .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
                if let preview {
                    VStack {
                        HStack { Text(target.filename).lineLimit(1); Spacer(); Button("Done") { self.preview = nil } }.padding()
                        MobileAttachmentQuickLook(url: preview)
                    }
                }
            }
            .sheet(item: $share) { item in MobileAttachmentShare(url: item.url) }
            .alert("Rename Attachment", isPresented: $rename) {
                TextField("Filename", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Rename") { perform { try editor.renameAttachment(target, to: name); dismiss() } }
            } message: { Text("The original file remains available for Undo.") }
            .confirmationDialog("Image Size", isPresented: $resize, titleVisibility: .visible) {
                ForEach([160, 320, 640, 960], id: \.self) { size in
                    Button("\(size) points") { perform { try editor.resizeAttachment(target, width: size); dismiss() } }
                }
                Button("Natural Size (Fit Note)") { perform { try editor.resizeAttachment(target, width: nil); dismiss() } }
            }
            .confirmationDialog("Remove this attachment from the note?", isPresented: $remove, titleVisibility: .visible) {
                Button("Remove from Note", role: .destructive) { perform { try editor.removeAttachment(target); dismiss() } }
            } message: { Text("This removes the link. Undo can restore it.") }
            .alert("Attachment", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}

private struct MobileAttachmentShareItem: Identifiable { let id = UUID(); let url: URL }
private struct MobileAttachmentShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
private struct MobileAttachmentQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; controller.reloadData() }
    }
    @MainActor final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}

@MainActor enum MobileSketchDraftProtectionPolicy {
    /// Missing/unreadable note state is never evidence that plaintext is safe.
    static func resolve(requiresProtection: Bool, access: LockedNoteAccess?,
                        readNote: () throws -> Note?) -> MobileSketchDraftStore.Protection? {
        do {
            guard let note = try readNote(), note.deletedAt == nil else { return nil }
            if requiresProtection || note.isLocked {
                guard let access else { return nil }
                return .sealed(access)
            }
            return .plain
        } catch { return nil }
    }
}

/// Main-actor ownership of one recovery record. Storage remains actor-owned; no vault key is cached.
@MainActor final class MobileSketchDraftHost {
    enum Failure: LocalizedError {
        case stale, keyRequired, unconfirmed, checkpointFailed
        var errorDescription: String? {
            switch self {
            case .stale: "The note or library changed while saving. Your drawing is kept; try Done again, or restore a copy if the original is unavailable."
            case .keyRequired: "Unlock locked notes to keep this recovered drawing protected."
            case .unconfirmed: "The previous save could not be confirmed. This draft is kept; another write is blocked. Check the note or explicitly restore a copy in a new note."
            case .checkpointFailed: "The recovery checkpoint could not be saved. Your open drawing is kept; try again before leaving."
            }
        }
    }
    let id: UUID
    let control = MobileSketchDraftControl()
    private let owner: UUID
    let originalNoteID: String?
    let sourceFilename: String?
    let sourceSHA256: String?
    private let store: MobileSketchDraftStore
    private let boundary: @MainActor () -> Bool
    private let protection: @MainActor () -> MobileSketchDraftStore.Protection?
    private(set) var generation: Int
    private var state: MobileSketchDraftStore.State
    private var accepting = true
    private var attempted = false
    private var saveFailed = false
    var keepsDraftOnCancel: Bool { saveFailed || attempted || state == .insertionUnconfirmed }
    func recordSaveFailure() { saveFailed = true }
    /// Includes editor-local validation failures which never reached the writer callback.
    func prepareToKeepAfterSaveFailure() async throws {
        recordSaveFailure()
        try await prepareToKeepDraft()
    }
    /// Complete persistence before closing the only live canvas. Failure keeps that canvas open.
    func prepareToKeepDraft() async throws {
        guard try await waitForCheckpoint() else { throw Failure.checkpointFailed }
        guard let summary = try await store.discover().first(where: { $0.id == id }),
              summary.generation == 0 || summary.generation >= generation else { throw Failure.checkpointFailed }
        accepting = false
        await store.release(id, owner: owner)
    }
    private let explicitCopy: Bool
    private var lastWrite: Task<Bool, any Error>?
    private var issuingCheckpointRetry = false
    private var suspendedWithoutContent = false

    init(store: MobileSketchDraftStore, owner: UUID, id: UUID = UUID(), generation: Int = 0,
         originalNoteID: String?, sourceFilename: String? = nil, sourceSHA256: String? = nil,
         state: MobileSketchDraftStore.State = .editing, explicitCopy: Bool = false,
         boundary: @escaping @MainActor () -> Bool,
         protection: @escaping @MainActor () -> MobileSketchDraftStore.Protection?) {
        self.store = store; self.owner = owner; self.id = id; self.generation = generation
        self.originalNoteID = originalNoteID; self.sourceFilename = sourceFilename; self.sourceSHA256 = sourceSHA256
        self.state = state; self.explicitCopy = explicitCopy; self.boundary = boundary; self.protection = protection
    }
    func reserveFresh() async throws -> Bool { try await store.reserveFresh(id, owner: owner) }
    /// The caller supplies a source authenticated by load(). Forking never retargets or
    /// consumes that source; the destination has an independent claim and journal.
    func establishRecoveredCopy(from source: MobileSketchDraftStore.Draft) async throws {
        guard accepting, boundary(), id != source.id, originalNoteID != source.originalNoteID else { throw Failure.stale }
        let sourceAdmission = store.captureAdmission(for: source.originalNoteID)
        let targetAdmission = store.captureAdmission(for: originalNoteID)
        guard let strategy = protection() else { throw Failure.keyRequired }
        guard try await store.renewClaim(source.id, owner: owner, protection: strategy, admission: sourceAdmission),
              boundary() else { throw Failure.stale }
        guard try await reserveFresh() else { throw Failure.stale }
        generation = 1; state = .editing
        let fork = MobileSketchDraftStore.Draft(id: id, generation: generation, originalNoteID: originalNoteID,
            drawingData: source.drawingData, canvasSize: source.canvasSize, state: .editing)
        let store = store
        lastWrite = Task {
            try Task.checkCancellation()
            return try await store.checkpoint(fork, protection: strategy, admission: targetAdmission)
        }
        do {
            guard try await waitForCheckpoint(), boundary(),
                  try await store.renewClaim(source.id, owner: owner, protection: strategy, admission: sourceAdmission),
                  boundary() else { throw Failure.stale }
            try Task.checkCancellation()
        } catch {
            await store.release(id, owner: owner)
            throw error // A partial/uncertain destination remains recoverable; source is untouched.
        }
    }
    func checkpoint(_ snapshot: MobileSketchCheckpoint) {
        guard accepting, boundary(), generation < Int.max else { return }
        let admission = store.captureAdmission(for: originalNoteID)
        let canRetry = !issuingCheckpointRetry
        generation += 1
        let draft = MobileSketchDraftStore.Draft(id: id, generation: generation, originalNoteID: originalNoteID,
            sourceFilename: sourceFilename, sourceSHA256: sourceSHA256,
            drawingData: snapshot.drawingData, canvasSize: snapshot.canvasSize, state: state)
        let previous = lastWrite, store = store
        lastWrite = Task { [self] in
            _ = try? await previous?.value
            do {
                guard boundary() else { throw Failure.stale }
                guard let strategy = self.protection() else { throw Failure.keyRequired }
                guard try await store.renewClaim(draft.id, owner: owner, protection: strategy, admission: admission), boundary() else { throw Failure.stale }
                return try await store.checkpoint(draft, protection: strategy, admission: admission)
            } catch {
                // A newer checkpoint already owns retry/error delivery for its own canvas.
                if self.generation == draft.generation {
                    let retry = error is CancellationError && canRetry && accepting && boundary() && !Task.isCancelled
                    issuingCheckpointRetry = retry
                    _ = control.checkpointFailed(retry: retry)
                    issuingCheckpointRetry = false
                }
                throw error
            }
        }
    }
    @discardableResult func waitForCheckpoint() async throws -> Bool {
        while let pending = lastWrite {
            let observedGeneration = generation
            do {
                let result = try await pending.value
                if observedGeneration != generation { continue }
                return result
            } catch {
                if observedGeneration != generation { continue }
                throw error
            }
        }
        return false
    }
    /// Must precede the actual writer: a crash/uncertain ACK cannot authorize blind replay.
    func prepareForWrite() async throws {
        guard accepting, boundary() else { throw Failure.stale }
        guard !attempted, state != .insertionUnconfirmed || explicitCopy else { throw Failure.unconfirmed }
        guard try await waitForCheckpoint() else { throw Failure.checkpointFailed }
        let admission = store.captureAdmission(for: originalNoteID)
        guard boundary(), let protection = protection() else { throw Failure.keyRequired }
        guard try await store.renewClaim(id, owner: owner, protection: protection, admission: admission), boundary() else { throw Failure.stale }
        guard let next = try await store.markInsertionUnconfirmed(id, protection: protection, admission: admission) else { throw Failure.checkpointFailed }
        generation = max(generation, next); state = .insertionUnconfirmed; attempted = true
    }
    /// Cancel after any failed/uncertain save means keep recovery. Only an ordinary,
    /// explicitly confirmed pre-save discard may remove the record.
    func cancelByUser() async throws {
        if keepsDraftOnCancel { try await prepareToKeepDraft() }
        else { try await discard() }
    }
    func confirmedSave() async throws {
        accepting = false
        try await store.delete(id)
    }
    /// Best effort only. The caller hides/locks immediately; a revoked key keeps the last durable record.
    func suspend() {
        // nil can also mean invalid/unavailable capture. Skip only explicit proof
        // from a still-attached untouched blank canvas and no queued checkpoint.
        if accepting { suspendedWithoutContent = control.hasUntouchedBlankCanvas && lastWrite == nil }
        _ = control.checkpointNow(force: true); accepting = false
        let pending = lastWrite, store = store, id = id, owner = owner
        Task { _ = try? await pending?.value; await store.release(id, owner: owner) }
    }
    func completeSuspendedCheckpoint() async throws {
        if suspendedWithoutContent { return }
        guard try await waitForCheckpoint() else { throw Failure.checkpointFailed }
    }
    func discard() async throws { accepting = false; try await store.delete(id) }
}

@MainActor enum MobileSketchDraftRestorePolicy {
    /// A sync lock can precede draft encryption. Such file-protected residuals remain
    /// hidden until unlock/upgrade; a missing history with a vault is conservatively private.
    static func requiresProtection(storedProtected: Bool, hasVault: Bool,
                                   readOriginal: () throws -> Note?) -> Bool {
        if storedProtected { return true }
        do {
            guard let note = try readOriginal(), note.deletedAt == nil else { return hasVault }
            return note.isLocked
        } catch { return true }
    }
    /// The only permissible new target for a protected draft is already locked BEFORE
    /// any drawing bytes, filename or image link is inserted. A failure keeps the draft.
    static func copyFailureMessage(targetMayRemain: Bool, detail: String) -> String {
        "The draft was kept. " + detail + (targetMayRemain
            ? " A new empty note may have been left behind. You can delete that note after checking it; your original recovery draft is unchanged."
            : " If the original changed or is unavailable, choose Recovered Sketches and restore in a new note.")
    }
    static func createNewTarget(library: MobileLibrary, protected: Bool) throws -> String {
        guard !library.appLocked, !library.isClosed, !library.isClosing, !library.libraryOperationBusy else { throw MobileSketchDraftHost.Failure.stale }
        if protected { guard library.privateAccess != nil else { throw MobileSketchDraftHost.Failure.keyRequired } }
        let empty = try library.store.create(text: "")
        if protected { try library.lockNote(empty.id) }
        let stored = try library.store.note(id: empty.id)
        guard !protected || stored?.isLocked == true else { throw MobileSketchDraftHost.Failure.keyRequired }
        return empty.id
    }
    /// Resolve a unique current link with the parser, never a stored UTF-16 range.
    static func freshTarget(filename: String, text: String, noteID: String) -> MobileAttachmentTarget? {
        let links = NoteParser.attachmentLinks(in: text).filter { $0.filename == filename }
        guard links.count == 1, let link = links.first,
              let start = text.utf8.index(text.utf8.startIndex, offsetBy: link.offset, limitedBy: text.utf8.endIndex),
              let index = String.Index(start, within: text) else { return nil }
        let suffix = String(text[index...].prefix(8192))
        // Same single-link syntax accepted by AttachmentMarkdown. Trailing metadata stays
        // outside this range, so the destination-only replacement preserves it byte-for-byte.
        guard let regex = try? NSRegularExpression(pattern: #"^!?\[((?:\\.|[^\\\]])*)\]\(([^()\s<>]+|<[^<>\n]*>)\)"#),
              let match = regex.firstMatch(in: suffix, range: NSRange(location: 0, length: (suffix as NSString).length)) else { return nil }
        let source = (suffix as NSString).substring(with: match.range)
        guard NoteParser.attachmentLinks(in: source).map(\.filename) == [filename],
              AttachmentMarkdown.renaming(source, to: filename) != nil else { return nil }
        let from = text[..<index].utf16.count
        return MobileAttachmentTarget(noteID: noteID, filename: filename, from: from, to: from + source.utf16.count, source: source)
    }
    static func canUseOriginal(_ draft: MobileSketchDraftStore.Draft, note: Note?, canRead: Bool,
                               currentHash: String? = nil, protected: Bool) -> Bool {
        guard let note, note.id == draft.originalNoteID, note.deletedAt == nil, note.location == .notes,
              !note.isReadOnly, canRead, !protected || note.isLocked else { return false }
        if let hash = draft.sourceSHA256 { return hash == currentHash }
        return draft.sourceFilename == nil
    }
}

@MainActor enum MobileSketchDraftNavigation {
    static let open = Notification.Name("MobileSketchDraftNavigation.open")
}

/// Opaque recovery management: never loads drawing archives or note metadata.
@MainActor @Observable final class MobileSketchRecoveryCapacityModel: Identifiable {
    let id = UUID()
    private let store: MobileSketchDraftStore
    private let currentDraftID: UUID
    private let owner = UUID()
    private let allowed: @MainActor () -> Bool
    private(set) var items: [MobileSketchDraftStore.Summary] = []
    enum Failure: LocalizedError {
        case unavailable, busy
        var errorDescription: String? {
            switch self {
            case .unavailable: "Recovery management is unavailable while the library is locked or changing."
            case .busy: "This recovery draft is open in another window. Close that editor first."
            }
        }
    }
    init(store: MobileSketchDraftStore, currentDraftID: UUID, allowed: @escaping @MainActor () -> Bool) {
        self.store = store; self.currentDraftID = currentDraftID; self.allowed = allowed
    }
    func refresh() async throws {
        guard allowed() else { throw Failure.unavailable }
        let found = try await store.discover()
        guard allowed() else { throw Failure.unavailable }
        items = found.filter { $0.id != currentDraftID }
    }
    /// Called only after explicit confirmation. The current canvas is never a candidate.
    func discardSavedDraft(_ id: UUID) async throws {
        guard id != currentDraftID, allowed() else { throw Failure.unavailable }
        guard try await store.claim(id, owner: owner) else { throw Failure.busy }
        do {
            guard allowed() else { throw Failure.unavailable }
            guard try await store.deleteClaimed(id, owner: owner) else { throw Failure.busy }
            await store.release(id, owner: owner)
        } catch {
            await store.release(id, owner: owner)
            throw error
        }
        try await refresh()
    }
}

struct MobileSketchRecoveryCapacityView: View {
    @Bindable var model: MobileSketchRecoveryCapacityModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: UUID?
    @State private var errorMessage: String?
    @State private var busy = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recovery Drafts").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.disabled(busy)
            }.padding()
            List {
                Section {
                    Text("Your current canvas stays open. To free space, explicitly discard a different saved recovery draft, then return and retry saving.")
                }
                Section("Other recovery drafts (\(model.items.count))") {
                    ForEach(model.items, id: \.id) { item in
                        Button(role: .destructive) { candidate = item.id } label: {
                            VStack(alignment: .leading) {
                                Text(item.isProtected ? "Protected drawing" : "Saved drawing")
                                Text(String(item.id.uuidString.prefix(8))).font(.caption.monospaced())
                            }
                        }.disabled(busy)
                    }
                }
            }
            .task { do { try await model.refresh() } catch { errorMessage = error.localizedDescription } }
            .confirmationDialog("Permanently discard this other recovery draft?", isPresented: Binding(
                get: { candidate != nil }, set: { if !$0 { candidate = nil } }), titleVisibility: .visible) {
                if let id = candidate {
                    Button("Discard Recovery Draft", role: .destructive) {
                        candidate = nil; busy = true
                        Task {
                            defer { busy = false }
                            do { try await model.discardSavedDraft(id) } catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { candidate = nil }
            } message: { Text("Saved notes and attachments are unchanged. Your current drawing is kept.") }
            .alert("Recovery Drafts", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }.privacySensitive()
    }
}
