// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// Everything a command reads from the outside world besides the library, so tests can fix it.
public struct AutomationContext: Sendable {
    public var now: @Sendable () -> Date
    public var calendar: Calendar
    public var locale: Locale
    public var environment: [String: String]
    /// Fetches the URL of `attachments add-url`; tests put a stub here.
    public var fetcher: any URLFetcher
    /// The largest attachment `attachments add` and `add-url` take (ruling M5-R6).
    public var maxAttachmentBytes: Int
    /// The library used when no `--data-dir` is given. Tests point it at a throw-away folder so a
    /// command never reaches the real library or the real app.
    public var production: AppPaths
    /// The user's home folder, where a long data dir's socket lives (ruling M5-R16).
    public var home: URL
    /// Starts the app by opening a `theonotes://` URL (ruling M5-R17); tests put a spy here.
    public var launcher: @Sendable (URL) throws -> Void

    public init(
        now: @escaping @Sendable () -> Date, calendar: Calendar, locale: Locale, environment: [String: String],
        fetcher: any URLFetcher = HTTPSFetcher(), maxAttachmentBytes: Int = HTTPSFetcher.maxBytes,
        production: AppPaths = .production, home: URL = AutomationContext.defaultHome,
        launcher: @escaping @Sendable (URL) throws -> Void = AutomationContext.openWithSystem
    ) {
        self.production = production
        self.home = home
        self.launcher = launcher
        self.maxAttachmentBytes = maxAttachmentBytes
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.environment = environment
        self.fetcher = fetcher
    }

    /// The wall clock; calendar and locale follow system settings changes (a long-running
    /// `mcp-server` must not keep the time zone it started with).
    public static let live = AutomationContext(
        now: { Date() }, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent,
        environment: ProcessInfo.processInfo.environment)

    /// The user's home folder. iOS (which links this module for its x-callback path) has no
    /// `homeDirectoryForCurrentUser`; its app sandbox home stands in.
    public static var defaultHome: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    /// `/usr/bin/open <url>`: the system starts the app registered for the URL scheme. macOS only:
    /// on iOS nothing launches the app this way.
    public static let openWithSystem: @Sendable (URL) throws -> Void = { url in
        #if !os(macOS)
        throw AutomationError(code: .appUnavailable, message: "Theo Notes could not be launched")
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AutomationError(code: .appUnavailable, message: "Theo Notes could not be launched")
        }
        #endif
    }

    /// A clock stopped at `date`, UTC Gregorian calendar, `en_US_POSIX`, empty environment.
    public static func fixed(_ date: Date) -> AutomationContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Nothing real is reachable: a library and a home that do not exist, and a launcher that fails.
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("baerchen-nowhere-\(UUID().uuidString)", isDirectory: true)
        return AutomationContext(
            now: { date }, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"), environment: [:],
            production: AppPaths(root: nowhere.appendingPathComponent("Baerchen", isDirectory: true)),
            // Short, so the fallback socket path fits an address and the answer is "no socket", not "bad path".
            home: URL(fileURLWithPath: "/nonexistent/h", isDirectory: true),
            launcher: { _ in throw AutomationError(code: .appUnavailable, message: "Theo Notes could not be launched") })
    }
}
