// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CoreSpotlight
import Testing
import TheoNotesCore
import UIKit
import UniformTypeIdentifiers
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileNoteSceneActivationTests {
    @Test func addressRestoresStableWindowButExplicitOpenCreatesDistinctWindows() throws {
        let libraryID = String(repeating: "a", count: 64), noteID = UUID().uuidString
        let first = try MobileNoteSceneAddress(libraryID: libraryID, noteID: noteID)
        let second = try MobileNoteSceneAddress(libraryID: libraryID, noteID: noteID)
        #expect(first != second && first.windowID != second.windowID)
        #expect(try JSONDecoder().decode(MobileNoteSceneAddress.self, from: JSONEncoder().encode(first)) == first)
        #expect(try MobileNoteSceneActivation.address(from: MobileNoteSceneActivation.activity(for: first)) == first)
    }
    @Test func malformedAndForeignActivitiesAreRefused() throws {
        #expect(throws: (any Error).self) { try MobileNoteSceneAddress(libraryID: "/private/library", noteID: UUID().uuidString) }
        #expect(throws: (any Error).self) { try MobileNoteSceneAddress(libraryID: String(repeating: "b", count: 64), noteID: "../../secret") }
        let malformed = Data("{\"windowID\":\"\(UUID())\",\"libraryID\":\"invalid\",\"noteID\":\"\(UUID())\"}".utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MobileNoteSceneAddress.self, from: malformed) }
        #expect(throws: (any Error).self) { try MobileNoteSceneActivation.address(from: NSUserActivity(activityType: "untrusted.activity")) }
    }
    @Test func activityContainsOnlyOpaqueIDsAndNoSearchOrHandoffContent() throws {
        let address = try MobileNoteSceneAddress(libraryID: String(repeating: "a", count: 64), noteID: UUID().uuidString)
        let activity = MobileNoteSceneActivation.activity(for: address)
        #expect(activity.title == "Note")
        #expect(activity.webpageURL == nil && activity.contentAttributeSet == nil)
        #expect(!activity.isEligibleForHandoff && !activity.isEligibleForSearch && !activity.isEligibleForPublicIndexing)
        #expect(activity.userInfo?.count == 1)
        #expect(activity.targetContentIdentifier == address.windowID.uuidString)
    }
    @Test func capabilityRequiresIPadAndActualRuntimeSupport() {
        #expect(MobileNoteSceneActivation.supportsMultipleWindows(idiom: .pad, supportsScenes: true))
        #expect(!MobileNoteSceneActivation.supportsMultipleWindows(idiom: .phone, supportsScenes: true))
        #expect(!MobileNoteSceneActivation.supportsMultipleWindows(idiom: .pad, supportsScenes: false))
    }
    @Test func resolverRechecksLibraryPrivacyAndCurrentNoteWithoutChangingSelection() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "Private title must never enter activity")
        let address = try MobileNoteSceneActivation.address(noteID: note.id, library: library)
        if case .note(let found) = MobileNoteSceneActivation.resolve(address, library: library) { #expect(found.id == note.id) }
        else { Issue.record("Existing readable note should resolve") }
        #expect(library.selectedID == nil)
        let foreign = try MobileNoteSceneAddress(libraryID: String(repeating: "f", count: 64), noteID: note.id)
        if case .unavailable = MobileNoteSceneActivation.resolve(foreign, library: library) { }
        else { Issue.record("Foreign library must refuse routing") }
        try await library.unlockNotes(password: "fixture-password", createPassword: true)
        try library.lockNote(note.id); try library.lockVault()
        if case .waitingForUnlock = MobileNoteSceneActivation.resolve(address, library: library) { }
        else { Issue.record("Protected cold route must defer until unlock") }
        #expect(library.selectedID == nil)
    }
    @Test func dragRetainsPlainStringRepresentationForExistingTagDrops() async throws {
        let address = try MobileNoteSceneAddress(libraryID: String(repeating: "a", count: 64), noteID: UUID().uuidString)
        let provider = MobileNoteSceneActivation.dragProvider(for: address)
        #expect(provider.canLoadObject(ofClass: NSUserActivity.self))
        let loaded: String = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value = value as? NSString { continuation.resume(returning: value as String) }
                else { continuation.resume(throwing: CocoaError(.coderReadCorrupt)) }
            }
        }
        #expect(loaded == address.noteID)
        #expect(provider.suggestedName == "Note")
    }
}
