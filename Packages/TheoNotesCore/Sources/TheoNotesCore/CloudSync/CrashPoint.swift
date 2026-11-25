// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

public struct CrashInjected: Error, Equatable, Sendable {
    public let boundary: String
    public init(boundary: String) { self.boundary = boundary }
}

/// Injectable crash for tests: code calls `try crash.hit("name")` at a named boundary; a test arms a boundary and the next
/// hit throws `CrashInjected`. Production code passes `CrashPoint.never`.
public final class CrashPoint: @unchecked Sendable {
    private let lock = NSLock()
    private var armed: [String: Int] = [:]
    private var recorded: [String] = []
    private let inert: Bool

    public init() { inert = false }
    private init(inert: Bool) { self.inert = inert }

    public static let never = CrashPoint(inert: true)

    /// Throws on the (afterHits + 1)-th next hit of `boundary`, once.
    public func arm(_ boundary: String, afterHits: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        armed[boundary] = afterHits
    }

    public var hits: [String] { lock.lock(); defer { lock.unlock() }; return recorded }

    public func hit(_ boundary: String) throws {
        if inert { return }
        lock.lock(); defer { lock.unlock() }
        recorded.append(boundary)
        guard let remaining = armed[boundary] else { return }
        if remaining > 0 { armed[boundary] = remaining - 1; return }
        armed[boundary] = nil
        throw CrashInjected(boundary: boundary)
    }
}
