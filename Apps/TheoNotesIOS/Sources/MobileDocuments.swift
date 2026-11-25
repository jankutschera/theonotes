// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var textBundle: UTType { UTType(importedAs: "org.textbundle.package", conformingTo: .package) }
}

/// FileDocument crosses executor boundaries. Keep immutable bytes here, not a mutable FileWrapper.
private indirect enum ExportNode: Sendable {
    case file(Data)
    case directory([String: ExportNode])

    init(_ wrapper: FileWrapper) throws {
        if wrapper.isRegularFile, let contents = wrapper.regularFileContents { self = .file(contents) }
        else if wrapper.isDirectory, let files = wrapper.fileWrappers { self = .directory(try files.mapValues(ExportNode.init)) }
        else { throw CocoaError(.fileReadUnsupportedScheme) }
    }
    var wrapper: FileWrapper {
        switch self {
        case .file(let bytes): FileWrapper(regularFileWithContents: bytes)
        case .directory(let files): FileWrapper(directoryWithFileWrappers: files.mapValues(\.wrapper))
        }
    }
}

struct MobileExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .textBundle, .html, .pdf, .rtf, .zip] }
    private let node: ExportNode
    init(wrapper: FileWrapper) throws { node = try ExportNode(wrapper) }
    init(configuration: ReadConfiguration) throws { node = try ExportNode(configuration.file) }
    var fileSnapshot: FileWrapper { node.wrapper }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { fileSnapshot }
}
