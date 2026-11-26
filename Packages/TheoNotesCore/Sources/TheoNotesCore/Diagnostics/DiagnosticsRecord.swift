// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// One crash, hang or resource report, reduced to facts that cannot hold what a person wrote.
///
/// A record is what the platform adapters (MetricKit) build and what the store writes. It has no
/// free-text field: `facts` accepts only the keys in `allowedFactKeys`, each with a value of a fixed shape;
/// frames carry binary names, UUIDs and numbers. `scrubbed()` enforces that again at the point of writing, so a
/// careless adapter, or a field a future OS adds, cannot put note text into a file.
public struct DiagnosticsRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case crash, hang, cpuException, diskWriteException, other
    }

    public struct Frame: Codable, Equatable, Sendable {
        /// Depth in the call stack tree (0 = a root frame).
        public var depth: Int
        public var binaryName: String?
        public var binaryUUID: String?
        public var offset: UInt64?
        public var address: UInt64?
        public var samples: Int?

        public init(
            depth: Int, binaryName: String?, binaryUUID: String?, offset: UInt64?, address: UInt64?, samples: Int?
        ) {
            self.depth = depth
            self.binaryName = binaryName
            self.binaryUUID = binaryUUID
            self.offset = offset
            self.address = address
            self.samples = samples
        }
    }

    /// One thread's call stack tree, flattened depth first.
    public struct CallStack: Codable, Equatable, Sendable {
        public var attributed: Bool
        public var frames: [Frame]

        public init(attributed: Bool, frames: [Frame]) {
            self.attributed = attributed
            self.frames = frames
        }
    }

    public static let currentSchemaVersion = 1
    /// Upper bounds applied by `scrubbed()`: a stack tree of a busy app can run to thousands of frames.
    public static let maxStacks = 64
    public static let maxFramesPerReport = 1_000

    /// The only keys `facts` may carry, with the shape a value must have (see `isAcceptable(_:forFact:)`).
    public static let allowedFactKeys: Set<String> = [
        "signal", "exceptionType", "exceptionCode", "terminationReason", "terminationCategory",
        "exceptionClass", "exceptionName", "hangSeconds", "cpuSeconds", "sampledSeconds", "bytesWritten",
    ]

    public var schemaVersion: Int
    public var kind: Kind
    public var receivedAt: Date
    public var periodStart: Date?
    public var periodEnd: Date?
    public var appVersion: String
    public var appBuild: String?
    public var osVersion: String
    public var facts: [String: String]
    public var stacks: [CallStack]
    /// Set when the store had to cut frames to keep the file within its size limit.
    public var truncated: Bool

    public init(
        kind: Kind, receivedAt: Date, periodStart: Date?, periodEnd: Date?, appVersion: String, appBuild: String?,
        osVersion: String, facts: [String: String], stacks: [CallStack], truncated: Bool = false
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.kind = kind
        self.receivedAt = receivedAt
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.facts = facts
        self.stacks = stacks
        self.truncated = truncated
    }

    // MARK: Scrubbing

    /// The same record with everything that is not on the allow list removed or replaced by `unknown`.
    public func scrubbed() -> DiagnosticsRecord {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        copy.appVersion = Self.matches(appVersion, Self.versionPattern) ? appVersion : "unknown"
        copy.appBuild = appBuild.flatMap { Self.matches($0, Self.versionPattern) ? $0 : nil }
        copy.osVersion = Self.matches(osVersion, Self.osVersionPattern) ? osVersion : "unknown"
        var cleanFacts: [String: String] = [:]
        for (key, value) in facts where Self.allowedFactKeys.contains(key) {
            if let clean = Self.cleaned(value, forFact: key) { cleanFacts[key] = clean }
        }
        copy.facts = cleanFacts
        var remaining = Self.maxFramesPerReport
        var cleanStacks: [CallStack] = []
        for stack in stacks.prefix(Self.maxStacks) {
            let frames = stack.frames.prefix(remaining).map(Self.scrubbed)
            remaining -= frames.count
            cleanStacks.append(CallStack(attributed: stack.attributed, frames: Array(frames)))
        }
        copy.stacks = cleanStacks
        return copy
    }

    private static func scrubbed(_ frame: Frame) -> Frame {
        Frame(
            depth: max(0, min(frame.depth, 10_000)),
            binaryName: frame.binaryName.flatMap { matches($0, binaryNamePattern) ? $0 : nil },
            binaryUUID: frame.binaryUUID.flatMap { UUID(uuidString: $0)?.uuidString },
            offset: frame.offset, address: frame.address, samples: frame.samples.map { max(0, $0) })
    }

    // MARK: Shapes

    private static let versionPattern = "^[A-Za-z0-9._+-]{1,32}$"
    /// `macOS 27.0 (27A1)`, `iPhone OS 27.0 (27A5)`: a platform name, a number, an optional build.
    private static let osVersionPattern = "^[A-Za-z]{2,12}( [A-Za-z]{2,12})? [0-9]+(\\.[0-9]+){0,3}( \\([0-9A-Za-z]{1,12}\\))?$"
    /// `Theo Notes`, `libswiftCore.dylib`, `Google Chrome Helper (Renderer)`: a few words, no punctuation of text.
    private static let binaryNamePattern = "^[A-Za-z0-9._+()-]+( [A-Za-z0-9._+()-]+){0,3}$"
    private static let numberPattern = "^-?[0-9]{1,20}(\\.[0-9]{1,6})?$"
    private static let identifierPattern = "^[A-Za-z_][A-Za-z0-9_.-]{0,79}$"
    private static let terminationPattern = "^Namespace [A-Za-z_]{1,32}, Code (0x[0-9A-Fa-f]{1,16}|[0-9]{1,10})"

    /// Whether `value` has the shape that `key` allows.
    static func isAcceptable(_ value: String, forFact key: String) -> Bool { cleaned(value, forFact: key) != nil }

    private static func cleaned(_ value: String, forFact key: String) -> String? {
        switch key {
        case "signal", "exceptionType", "exceptionCode", "hangSeconds", "cpuSeconds", "sampledSeconds", "bytesWritten":
            return matches(value, numberPattern) ? value : nil
        case "terminationCategory", "exceptionClass", "exceptionName":
            return matches(value, identifierPattern) ? value : nil
        case "terminationReason":
            // The system writes `Namespace SIGNAL, Code 11 <explanation>`; only the namespace and code are kept.
            guard let range = value.range(of: terminationPattern, options: .regularExpression) else { return nil }
            return String(value[range])
        default:
            return nil
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Call stack trees as JSON

extension DiagnosticsRecord.CallStack {
    /// The stacks of a call stack tree in the JSON form of the older MetricKit API
    /// (`{"callStacks": [{"threadAttributed": …, "callStackRootFrames": [{…, "subFrames": […]}]}]}`).
    /// Only the frame fields are read; any other key is ignored. Garbage gives no stacks.
    public static func parse(callStackJSON data: Data) -> [DiagnosticsRecord.CallStack] {
        guard !data.isEmpty,
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let stacks = root["callStacks"] as? [[String: Any]]
        else { return [] }
        var budget = DiagnosticsRecord.maxFramesPerReport
        var result: [DiagnosticsRecord.CallStack] = []
        for stack in stacks.prefix(DiagnosticsRecord.maxStacks) {
            var frames: [DiagnosticsRecord.Frame] = []
            // Depth first without recursion: a pending list of (frame, depth), taken from the end.
            var pending: [([String: Any], Int)] = ((stack["callStackRootFrames"] as? [[String: Any]]) ?? [])
                .reversed().map { ($0, 0) }
            while let (frame, depth) = pending.popLast(), budget > 0 {
                budget -= 1
                frames.append(DiagnosticsRecord.Frame(
                    depth: depth, binaryName: frame["binaryName"] as? String, binaryUUID: frame["binaryUUID"] as? String,
                    offset: unsigned(frame["offsetIntoBinaryTextSegment"]), address: unsigned(frame["address"]),
                    samples: (frame["sampleCount"] as? NSNumber)?.intValue))
                let children = (frame["subFrames"] as? [[String: Any]]) ?? []
                pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
            result.append(DiagnosticsRecord.CallStack(
                attributed: (stack["threadAttributed"] as? Bool) ?? false, frames: frames))
        }
        return result
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, number.int64Value >= 0 else { return nil }
        return number.uint64Value
    }
}
