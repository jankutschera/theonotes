// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI
import ImageIO

struct MobileNoteRow: View {
    let note: NoteListItem
    let preferences: MobilePreferences
    let paths: AppPaths
    var searchTerms: [String] = []
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var thumbnail: UIImage?
    private func highlighted(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        guard !note.isLocked else { return value }
        for range in SearchOffsets.sourceRanges(for: searchTerms, in: text) {
            guard let native = Range(NSRange(location: range.lowerBound, length: range.count), in: text),
                  let attributed = Range(native, in: value) else { continue }
            value[attributed].backgroundColor = .yellow.opacity(0.35)
            value[attributed].foregroundColor = .primary
        }
        return value
    }
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if note.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Color.accentColor) }
                    if note.captureSource != nil { Image(systemName: "tray.and.arrow.down").font(.caption).accessibilityLabel("Captured") }
                    if let type = note.noteType {
                        Image(systemName: type == .idea ? "lightbulb" : type == .log ? "clock" : "bookmark")
                            .font(.caption).accessibilityLabel("Type: \(type.displayName)")
                    }
                    Text(highlighted(note.title.isEmpty ? "Untitled" : note.title))
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    if note.isLocked { Image(systemName: "lock.fill").font(.caption).accessibilityLabel("Locked") }
                    if note.isReadOnly { Image(systemName: "pencil.slash").font(.caption).accessibilityLabel("Read-only") }
                }
                if preferences.previewLines > 0 {
                    Text(highlighted(note.isLocked ? "Locked note" : note.subtitle))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : preferences.previewLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(note.modifiedAt, format: .dateTime.month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if preferences.showThumbnails, !note.isLocked, let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        .task(id: note.firstImageFilename) {
            guard !note.isLocked, preferences.showThumbnails, let name = note.firstImageFilename,
                  !name.contains("/"), name != ".", name != ".." else { thumbnail = nil; return }
            let url = paths.attachments.appendingPathComponent(note.id).appendingPathComponent(name)
            // Decode a bounded thumbnail, not a full-resolution photograph on the main actor.
            thumbnail = await Task.detached {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 156, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: image)
            }.value
        }
    }
}
