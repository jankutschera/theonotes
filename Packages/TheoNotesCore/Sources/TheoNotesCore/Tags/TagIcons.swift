// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import os

/// TagCons: SF Symbols for tags (spec §4.2). A tag shows its user-chosen icon, else the symbol
/// its last path component maps to in `Resources/tagcons.json` (English + German keywords,
/// case- and diacritic-insensitive), else `number`.
public enum TagIcons {
    public static let fallbackSymbol = "number"

    struct Group: Decodable, Sendable {
        var symbol: String
        var keywords: [String]
    }

    static func loadGroups() throws -> [Group] {
        guard let url = Bundle.module.url(forResource: "tagcons", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([Group].self, from: Data(contentsOf: url))
    }

    private static let groups: [Group] = {
        do {
            return try loadGroups()
        } catch {
            Logger(subsystem: "com.truebrewbirdie.baerchen", category: "tags").error("tagcons.json: \(error)")
            return []
        }
    }()

    /// Folded keyword → symbol (the first group naming a keyword wins).
    public static let keywordTable: [String: String] = {
        var table: [String: String] = [:]
        for group in groups {
            for keyword in group.keywords where table[fold(keyword)] == nil {
                table[fold(keyword)] = group.symbol
            }
        }
        return table
    }()

    /// General-purpose symbols the picker offers besides the keyword table's.
    private static let extraSymbols = [
        "number", "tag", "circle", "square", "triangle", "diamond", "hexagon", "seal", "heart.fill",
        "star.fill", "bolt.fill", "flag.fill", "bookmark.fill", "folder.fill", "paperclip", "pin",
        "bell", "gear", "paperplane", "location", "cloud", "umbrella", "bag", "basket", "lamp.desk",
        "sofa", "chair", "bathtub", "washer", "refrigerator", "fan", "lightbulb.fill", "keyboard",
        "display", "laptopcomputer", "applewatch", "dice", "theatermask.and.paintbrush", "music.mic",
        "photo", "wand.and.stars", "eye", "hand.raised", "figure.wave", "figure.yoga",
        "figure.outdoor.cycle", "basketball", "baseball", "football", "volleyball", "skateboard",
        "skis", "surfboard", "medal", "rosette", "globe.europe.africa", "house.fill", "building",
        "graduationcap.fill", "infinity", "atom", "hare", "tortoise", "ladybug", "teddybear",
    ]

    /// The picker grid: every keyword-table symbol (in file order), then the extras.
    public static let pickerSymbols: [String] = {
        var seen = Set<String>()
        return (groups.map(\.symbol) + extraSymbols).filter { seen.insert($0).inserted }
    }()

    private static let keywordsBySymbol: [String: [String]] = {
        var map: [String: [String]] = [:]
        for group in groups { map[group.symbol, default: []] += group.keywords.map(fold) }
        return map
    }()

    public static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The keyword match for the path's last component, else `number`.
    public static func defaultSymbol(forTagPath path: String) -> String {
        guard let last = path.split(separator: "/").last else { return fallbackSymbol }
        return keywordTable[fold(String(last))] ?? fallbackSymbol
    }

    /// The icon a tag shows: `iconName` when set, else `defaultSymbol(forTagPath:)`.
    public static func symbol(forTagPath path: String, iconName: String?) -> String {
        if let iconName, !iconName.isEmpty { return iconName }
        return defaultSymbol(forTagPath: path)
    }

    /// Picker symbols whose name or keywords (any language) contain `query`; all for an empty query.
    public static func searchSymbols(_ query: String) -> [String] {
        let query = fold(query)
        guard !query.isEmpty else { return pickerSymbols }
        return pickerSymbols.filter { symbol in
            symbol.contains(query) || (keywordsBySymbol[symbol] ?? []).contains { $0.contains(query) }
        }
    }
}
