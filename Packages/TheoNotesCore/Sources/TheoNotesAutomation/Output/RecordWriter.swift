// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

public enum OutputFormat: String, Sendable, CaseIterable {
    case tsv, csv, json
}

/// One cell of a record, before it is rendered in a format.
public enum FieldValue: Equatable, Sendable {
    case string(String)
    /// Text that carries its `\n \t \r \\` escapes already (a `search-in` snippet): written as it
    /// is in every format, TSV included.
    case escaped(String)
    case int(Int)
    /// `yes` / `no` in every format.
    case flag(Bool)
    /// `,`-joined in TSV and CSV, an array in JSON.
    case list([String])
    /// Empty in TSV and CSV, `null` in JSON.
    case null
}

public enum RecordWriter {
    /// No header; each row ends in `\n`; `\n \r \t \\` escaped inside fields.
    public static func tsv(_ rows: [[FieldValue]]) -> String {
        rows.map { row in row.map { plain($0, escape: TextEscapes.escapeTSV) }.joined(separator: "\t") + "\n" }.joined()
    }

    /// RFC 4180 with a header row; rows end in `\n`; a field with a comma, quote or line break
    /// is quoted and keeps its line breaks raw.
    public static func csv(header: [String], _ rows: [[FieldValue]]) -> String {
        // Unicode scalars, not Characters: a quote or comma followed by a combining mark or ZWJ
        // is one grapheme cluster that no Character comparison would match.
        func quoted(_ s: String) -> String {
            guard s.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
            var out = String.UnicodeScalarView()
            out.append("\"")
            for scalar in s.unicodeScalars {
                if scalar == "\"" { out.append("\"") }
                out.append(scalar)
            }
            out.append("\"")
            return String(out)
        }
        let lines = [header.map(quoted)] + rows.map { $0.map { quoted(plain($0, escape: { $0 })) } }
        return lines.map { $0.joined(separator: ",") + "\n" }.joined()
    }

    public static func jsonObject(_ fields: [(String, FieldValue)]) -> JSONValue {
        .object(fields.map { ($0.0, json($0.1)) })
    }

    private static func plain(_ value: FieldValue, escape: (String) -> String) -> String {
        switch value {
        case .string(let s): escape(s)
        case .escaped(let s): s
        case .int(let n): String(n)
        case .flag(let on): on ? "yes" : "no"
        case .list(let items): items.map(escape).joined(separator: ",")
        case .null: ""
        }
    }

    private static func json(_ value: FieldValue) -> JSONValue {
        switch value {
        case .string(let s), .escaped(let s): .string(s)
        case .int(let n): .int(n)
        case .flag(let on): .string(on ? "yes" : "no")
        case .list(let items): .array(items.map { .string($0) })
        case .null: .null
        }
    }
}
