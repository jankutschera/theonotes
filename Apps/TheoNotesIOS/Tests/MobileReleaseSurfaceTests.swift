// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore
@testable import BaerchenIOS

// Task 16 fix round 1, items 6 and 7: the private-server "Sync" page exists only where THEONOTES_SYNC_SETUP is YES (REL-R5/R6/R9),
// and an export the person chooses is a .theonotes-backup while the internal copies keep the legacy name (REN2-R37, REN2-R50).

@MainActor @Suite(.serialized) struct MobileReleaseSurfaceTests {
    private let key = ReleaseFeatures.syncSetupInfoKey

    private func library() throws -> (MobileLibrary, URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("MobileSurface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return (try MobileLibrary(paths: AppPaths(root: parent.appendingPathComponent("Library", isDirectory: true))), parent)
    }

    // MARK: 6. the private-server page

    @Test func aBuildWithoutTheSyncSetupFlagHasNoPrivateServerPageAndMakesNoController() throws {
        let (library, parent) = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: parent) }
        for (name, info) in [("missing", [String: Any]()), ("NO", [key: "NO"]), ("unsubstituted", [key: "$(THEONOTES_SYNC_SETUP)"]),
                             ("empty", [key: ""])] as [(String, [String: Any])] {
            #expect(!MobilePrivateServerSync.isAvailable(infoDictionary: info), "\(name)")
            #expect(MobilePrivateServerSync.controller(for: library, infoDictionary: info) == nil, "\(name): nothing is constructed")
        }
        #expect(MobilePrivateServerSync.isAvailable(infoDictionary: [key: "YES"]))
        #expect(MobilePrivateServerSync.controller(for: library, infoDictionary: [key: "YES"]) != nil)
    }

    @Test func theInfoPlistCarriesTheSyncSetupFlag() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info[key] as? String == "YES", "Debug is Jan's own build: the flag is on, Release is NO (project.yml)")
        #expect(MobilePrivateServerSync.isAvailable())
    }

    @Test func noCallerOutsideTheHelperBuildsThePrivateServerController() throws {
        // `library.sync` builds the controller on first use. Only the helper (and MobileLibrary itself, and the library view, which the
        // iOS owner edits) may name it; everything else asks the helper, so a build without the flag never makes one.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let allowed: Set<String> = ["MobileLibrary.swift", "MobileLibraryView.swift", "MobilePrivateServerSync.swift"]
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 10)
        for file in files where !allowed.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in ["library.sync.", "library.sync)", "current.sync.", "current.sync\n", "(sync: library.sync"] {
                #expect(!text.contains(pattern), "\(file.lastPathComponent) builds the private-server controller directly (\(pattern))")
            }
        }
    }

    // MARK: 7. export type

    @Test func anExportCopyIsATheonotesBackupAndTheInternalCopyKeepsTheLegacyName() async throws {
        let (library, parent) = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: parent) }
        let note = try library.store.create(text: "# Exported\n")
        let internalCopy = try await library.makeBackup()
        #expect(internalCopy.pathExtension == LegacyNames.backupExtension, "the app's own copies keep the legacy type")
        #expect(internalCopy.lastPathComponent.hasPrefix("baerchen-"))

        let exported = try MobileBackupExportFile.make(from: internalCopy, date: Date(timeIntervalSince1970: 1_793_300_000))
        defer { MobileBackupExportFile.discard(exported) }
        #expect(exported.pathExtension == "theonotes-backup")
        #expect(exported.pathExtension == LibraryBackup.backupExtension)
        #expect(exported.lastPathComponent.hasPrefix("Theo Notes Backup 20"), "\(exported.lastPathComponent)")
        #expect(try Data(contentsOf: exported) == Data(contentsOf: internalCopy), "the archive is the same bytes")
        #expect(FileManager.default.fileExists(atPath: internalCopy.path), "the internal copy was not renamed or moved")

        // both restore: the same inspection (what the restore picker runs) accepts the legacy file and the export
        let backup = LibraryBackup(database: library.database, paths: library.paths)
        let fromInternal = try backup.inspect(internalCopy)
        let fromExport = try backup.inspect(exported)
        #expect(fromExport.noteCount == fromInternal.noteCount && fromExport.noteCount >= 1)
        _ = note

        MobileBackupExportFile.discard(exported)
        #expect(!FileManager.default.fileExists(atPath: exported.deletingLastPathComponent().path), "the temporary folder is removed")
        #expect(FileManager.default.fileExists(atPath: internalCopy.path), "discarding an export never touches the original")
    }

    @Test func discardOnlyRemovesItsOwnTemporaryFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("not-an-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: folder) }
        MobileBackupExportFile.discard(file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func theInfoPlistDeclaresTheExportedTypeAndStillImportsTheLegacyOne() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let exported = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let entry = try #require(exported.first { $0["UTTypeIdentifier"] as? String == "com.truebrewbirdie.theonotes.backup" })
        let tags = try #require(entry["UTTypeTagSpecification"] as? [String: Any])
        #expect(tags["public.filename-extension"] as? [String] == [LibraryBackup.backupExtension])
        let imported = try #require(info["UTImportedTypeDeclarations"] as? [[String: Any]])
        let legacy = try #require(imported.first { $0["UTTypeIdentifier"] as? String == LegacyNames.backupUTI })
        let legacyTags = try #require(legacy["UTTypeTagSpecification"] as? [String: Any])
        #expect(legacyTags["public.filename-extension"] as? [String] == [LegacyNames.backupExtension])
        #expect(imported.contains { $0["UTTypeIdentifier"] as? String == "org.textbundle.package" }, "the TextBundle import is still declared")
    }
}
