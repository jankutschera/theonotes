// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import OSLog
import TheoNotesCore
import WidgetKit

private let mobileShareLogger = Logger(subsystem: MobileIdentity.bundleIdentifier, category: "ShareInbox")

@MainActor enum MobileShareContainer {
    static func reloadWidgets() { WidgetCenter.shared.reloadAllTimelines() }
    static func scrubWidgets(in container: URL?) throws {
        guard let container else { return }
        try MobileCardPublicationPublisher.scrubForStartup(in: container)
        reloadWidgets()
    }

    static func scrubRecentNotes(in container: URL?) -> String? {
        guard let container else { return nil }
        do { try SharedContainerFiles.publish(nil, in: container); return nil }
        catch { return "The shared note list could not be cleared. Sharing is unavailable." }
    }

    static func usesProductionContainer(arguments: [String], shortcutsUITesting: Bool) -> Bool {
        #if DEBUG
        return !arguments.contains("--ui-testing") && !shortcutsUITesting
        #else
        return true
        #endif
    }

    static func resolve() -> URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "THEONOTES_AppGroupIdentifier") as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
}

extension MobileLibrary {
    // The flag is claimed before awaiting the editor: two scene activations share one drain.
    @discardableResult func drainShareInbox() async throws -> [String] {
        guard sharingEnabled, !drainingShareInbox, !appLocked, !libraryOperationBusy,
              !isClosed, !isClosing else { return [] }
        guard let shareInbox else { return [] }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: shareInbox.directory.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return [] }
        guard names.contains(where: { $0.hasSuffix(".capture") }) else { return [] }
        drainingShareInbox = true
        defer { drainingShareInbox = false }
        return try await withDrainedShareEditors {
            guard !appLocked, !libraryOperationBusy, !isClosed, !isClosing, let currentInbox = self.shareInbox else { return [] }
            try flush()
            let ids = try currentInbox.drain(into: store, attachments: AttachmentStore(paths: paths, database: database))
            try refreshSessions()
            publishRecentNotes()
            return ids
        }
    }

    func drainShareInboxOnActivation() async {
        for attempt in 0..<2 {
            do { try await drainShareInbox(); return }
            catch let error as MobileEditorDrainError {
                mobileShareLogger.info("Shared items remain queued until the editors can finish saving.")
                guard error == .unavailable, attempt == 0 else { return }
                do { try await Task.sleep(for: .milliseconds(1500)) }
                catch { return }
            } catch is CancellationError { return } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    func openShareContainer() {
        guard sharingError == nil else { return }
        guard let shareContainer, SharedContainerFiles.validate(container: shareContainer) else {
            sharingError = "Sharing is unavailable because the shared app container could not be opened."
            return
        }
        shareInbox = CaptureInbox(directory: shareContainer.appendingPathComponent("CaptureInbox", isDirectory: true))
        publishRecentNotes()
    }

    func clearSharePublication() throws {
        // This is the synchronous pre-mutation privacy boundary (including sync whose
        // exact mutation is unknown). Never wait for the GRDB observation to fence Spotlight.
        spotlightDidChange?()
        sharePublicationScrubPending = true
        widgetPublicationTask?.cancel()
        widgetPublicationTask = nil
        var failure: (any Error)?
        if let widgetPublisher {
            do { try widgetPublisher.scrub(); reloadWidgetTimelines() }
            catch { failure = error }
        }
        do {
            if let shareContainer { try SharedContainerFiles.publish(nil, in: shareContainer) }
            sharePublicationScrubPending = false
        } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    func clearSharePublicationForSync() {
        do { try clearSharePublication() }
        catch {
            mobileShareLogger.error("Shared publication cleanup failed: \(String(reflecting: type(of: error)), privacy: .public)")
        }
    }

    func publishRecentNotes() {
        defer { scheduleWidgetPublication() }
        guard let shareContainer, !isClosed, !libraryOperationBusy else { return }
        if sharePublicationScrubPending {
            do { try clearSharePublication() }
            catch {
                sharingError = "The shared note list could not be cleared."
                return
            }
        }
        guard sharingEnabled else { return }
        do {
            try SharedContainerFiles.publish(RecentNotesFile.make(store: store, appLockEnabled: appLockEnabled), in: shareContainer)
            if sharingError == "The shared note list could not be cleared." || sharingError == "The shared note list could not be updated." {
                sharingError = nil
            }
        } catch {
            // Never retain a previously readable picker after a publication failure.
            try? clearSharePublication()
            sharingError = "The shared note list could not be updated."
        }
    }

    private func scheduleWidgetPublication() {
        widgetPublicationTask?.cancel()
        guard let publisher = widgetPublisher, !isClosed, !isClosing, !libraryOperationBusy else { return }
        let libraryID = MobileCardPublication.libraryID(for: paths)
        let configurations = widgetConfigurations
        let debounce = widgetPublicationDebounce
        widgetPublicationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                try Task.checkCancellation()
                let selected = try await configurations(libraryID)
                guard !Task.isCancelled, let self, self.widgetPublisher === publisher,
                      !self.isClosed, !self.isClosing, !self.libraryOperationBusy else { return }
                let prepared = try await publisher.prepareInBackground(
                    configuredNoteIDs: selected.notes, configuredTagIDs: selected.tags)
                guard !Task.isCancelled, self.widgetPublisher === publisher,
                      !self.isClosed, !self.isClosing, !self.libraryOperationBusy else { return }
                _ = try publisher.publish(prepared)
                // publish may instead have scrubbed a now-ineligible snapshot. Both outcomes
                // need one reload; privacy boundaries already cancel superseded host tasks.
                self.reloadWidgetTimelines()
            } catch {
                guard !Task.isCancelled, let self, self.widgetPublisher === publisher else { return }
                do { try publisher.scrub(); self.reloadWidgetTimelines() }
                catch { self.sharingError = "Widget data could not be cleared." }
                if !publisher.needsScrub { self.sharingError = "Widget data could not be updated." }
            }
        }
    }
}
