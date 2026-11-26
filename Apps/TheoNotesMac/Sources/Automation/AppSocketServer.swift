// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesAutomation
import TheoNotesCore
import Darwin
import Foundation
import os

/// The app's end of the automation socket (`<library>/app.sock`): the `baerchen`
/// CLI and MCP server ask it to open a note or report the selection. One JSON line in, one out,
/// then the connection closes.
///
/// Only the user who runs the app may connect (socket mode 0600, and the peer's uid is checked with
/// `getpeereid`); a request line over 1 MiB closes the connection. Nothing is logged but
/// counts, uids and error codes: note text never reaches the log.
final class AppSocketServer: @unchecked Sendable {
    enum StartError: Error, Equatable, CustomStringConvertible {
        /// Another process answers on the socket: it keeps it, this instance starts no server.
        case alreadyRunning(String)
        /// Something that is not a socket (or not ours) is in the way; it is left alone.
        case occupied(String)
        case pathTooLong(String)
        /// The socket's folder is not ours alone (a symlink, another owner, group- or world-writable),
        /// so the socket would not be safe there.
        case unsafeDirectory(String)
        /// An existing lock file is not a regular file of ours with mode 0600.
        case unsafeLockFile(String)
        /// The volume does not support the exclusive rename that publishes the socket.
        case unsupportedVolume(String)
        case system(String, errno: Int32)

        var description: String {
            switch self {
            case .alreadyRunning: "another instance already serves this library's socket"
            case .occupied: "a file that is not this app's socket is in the way"
            case .pathTooLong: "the socket path is too long"
            case .unsafeDirectory: "the socket's folder is a link, belongs to someone else or is writable by others"
            case .unsafeLockFile: "the lock file is not a private file (mode 0600) that belongs to you"
            case .unsupportedVolume: "this volume does not support the exclusive rename the socket needs; running without the automation socket"
            case .system(let what, let code): "\(what) failed (errno \(code))"
            }
        }
    }

    typealias Handler = @Sendable (AppSocketRequest) async -> AppSocketResponse

    let path: String
    private let home: URL
    private let ownUID: uid_t
    private let peerUID: uid_t
    private let handler: Handler
    private let log = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "socket")

    private let acceptQueue = DispatchQueue(label: "com.truebrewbirdie.baerchen.socket.accept")
    private let workQueue = DispatchQueue(label: "com.truebrewbirdie.baerchen.socket.work", attributes: .concurrent)
    private let lock = NSLock()
    private var source: (any DispatchSourceRead)?
    private var boundInode: ino_t = 0
    private var boundDevice: dev_t = 0
    /// The held `flock` on `<socket>.lock`: this process is the one instance for this library until
    /// `stop`.
    private var lockFD: Int32 = -1
    private var running = 0
    private let requestTimeout: Duration
    private let handlerTimeout: Duration
    private let renameExclusive: @Sendable (String, String) -> Int32
    private let stagingSuffix: @Sendable () -> UInt32

    /// Connection slots in use, a handler that has timed out still counting until it ends.
    var runningCount: Int { lock.withLock { running } }

    /// At most this many connections are served at once; more are closed at the door.
    static let maxConnections = 16
    /// How long the whole request line may take to arrive, and the whole reply to go out (ruling
    ///). Without a limit on the whole, a peer sending a byte at a time would keep a slot.
    static let defaultRequestTimeout: Duration = .seconds(10)
    /// How long a request may wait for the main actor before the caller gets an error.
    static let defaultHandlerTimeout: Duration = .seconds(20)

    /// `ownUID` and `home` are injectable for tests; the app uses the defaults.
    init(
        paths: AppPaths, home: URL = FileManager.default.homeDirectoryForCurrentUser, ownUID: uid_t = geteuid(),
        peerUID: uid_t? = nil, requestTimeout: Duration = AppSocketServer.defaultRequestTimeout,
        handlerTimeout: Duration = AppSocketServer.defaultHandlerTimeout,
        renameExclusive: @escaping @Sendable (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) },
        stagingSuffix: @escaping @Sendable () -> UInt32 = { UInt32.random(in: 0...UInt32.max) },
        handler: @escaping Handler
    ) {
        self.stagingSuffix = stagingSuffix
        self.handlerTimeout = handlerTimeout
        self.renameExclusive = renameExclusive
        self.home = home
        self.ownUID = ownUID
        // The user the files must belong to and the user who may connect are the same one; tests
        // separate them to play a foreign peer.
        self.peerUID = peerUID ?? ownUID
        self.requestTimeout = requestTimeout
        self.handler = handler
        path = AppSocket.path(for: paths, home: home)
    }

    deinit { stop() }

    var isStarted: Bool { lock.withLock { source != nil } }

    // MARK: - Start and stop

    /// Binds the socket and starts serving. Order: the folder must be ours and
    /// not writable by others; the start-up lock is taken (a second instance fails here,
    /// `alreadyRunning`); a stale socket file is replaced; the socket is bound in a private staging
    /// folder, checked and only then published.
    func start() throws {
        try lock.withLock {
            guard source == nil else { return }
            guard AppSocket.address(for: path) != nil else { throw StartError.pathTooLong(path) }
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            let isFallback = AppSocket.isFallback(path, home: home)
            if isFallback {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try verifyFolder(folder.path, repairing: isFallback)
            let held = try acquireStartLock()
            do {
                // Holding the lock, nobody else is starting: debris of a crashed start can go.
                sweepStagingFolders(in: folder.path)
                try replaceStaleSocket()
                let fd = try bindPrivateSocket()
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
                listener.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
                listener.setCancelHandler { close(fd) }
                lockFD = held
                source = listener
                listener.resume()
            } catch {
                close(held)
                throw error
            }
            log.notice("automation socket listening")
        }
    }

    /// Stops serving and removes the socket file, if it is still the one this server made.
    func stop() {
        let (listener, inode, device, held) = lock.withLock { () -> ((any DispatchSourceRead)?, ino_t, dev_t, Int32) in
            defer {
                source = nil
                lockFD = -1
            }
            return (source, boundInode, boundDevice, lockFD)
        }
        guard let listener else { return }
        listener.cancel()
        var info = stat()
        if lstat(path, &info) == 0, info.st_ino == inode, info.st_dev == device, (info.st_mode & S_IFMT) == S_IFSOCK {
            unlink(path)
        }
        // Closing the descriptor releases the lock; the lock file stays (unlinking it would let two
        // instances lock different files).
        if held >= 0 { close(held) }
    }

    /// The socket's folder: a real folder (not a symlink), ours, and writable by us alone, inside a
    /// folder that is ours or root's and that others cannot rename things in (not group- or
    /// world-writable, unless sticky like `/tmp`). The fallback folder is made 0700 if it is not; a
    /// library folder that others can write to is refused rather than changed. A swap of an ancestor by
    /// the same user between this check and the bind is accepted: it is outside the threat model, and
    /// macOS has no `bind` relative to a directory descriptor.
    private func verifyFolder(_ folder: String, repairing: Bool) throws {
        var info = stat()
        guard lstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == ownUID else {
            throw StartError.unsafeDirectory(folder)
        }
        if repairing, (info.st_mode & 0o777) != 0o700 {
            guard chmod(folder, 0o700) == 0, lstat(folder, &info) == 0 else { throw StartError.unsafeDirectory(folder) }
        }
        guard (info.st_mode & 0o022) == 0 else { throw StartError.unsafeDirectory(folder) }
        let parent = URL(fileURLWithPath: folder).deletingLastPathComponent().path
        var above = stat()
        // `stat`, not `lstat`: an ancestor such as /tmp may itself be a link.
        guard stat(parent, &above) == 0, (above.st_mode & S_IFMT) == S_IFDIR,
              above.st_uid == ownUID || above.st_uid == 0
        else { throw StartError.unsafeDirectory(parent) }
        if (above.st_mode & 0o022) != 0, (above.st_mode & S_ISVTX) == 0 { throw StartError.unsafeDirectory(parent) }
    }

    /// `flock` on `<socket>.lock`. A lock file that exists must be a regular file of ours with mode 0600,
    /// else the start is refused (it is logged); one that does not is created exclusively and
    /// set to 0600. Held for the life of the server: the kernel releases it when the process dies, which
    /// makes a leftover socket file provably stale. A same-user deletion of the lock file can split the
    /// brain (two instances locking different files); accepted, it is the user's own doing.
    private func acquireStartLock() throws -> Int32 {
        let lockPath = path + ".lock"
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC
        var fd = open(lockPath, flags)
        if fd < 0, errno == ENOENT {
            fd = open(lockPath, flags | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                // Ours, just made: its mode is ours to set, whatever the umask said.
                fchmod(fd, 0o600)
            } else if errno == EEXIST {
                fd = open(lockPath, flags)
            }
        }
        guard fd >= 0 else { throw StartError.system("open lock", errno: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == ownUID,
              (info.st_mode & 0o777) == 0o600
        else {
            close(fd)
            log.error("lock file refused: not a regular file of this user with mode 0600")
            throw StartError.unsafeLockFile(lockPath)
        }
        // A client checking the lock holds it shared for a moment; give it time to let go before
        // deciding that another instance is running.
        for attempt in 0..<6 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            let code = errno
            guard code == EWOULDBLOCK else {
                close(fd)
                throw StartError.system("flock", errno: code)
            }
            if attempt < 5 { usleep(40_000) }
        }
        close(fd)
        throw StartError.alreadyRunning(path)
    }

    /// Removes `.sock-*` staging folders of ours that a crashed start left behind (called only while the
    /// start-up lock is held). Failures are logged, never fatal.
    private func sweepStagingFolders(in folder: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        for name in names where name.hasPrefix(".sock-") {
            let staging = folder + "/" + name
            var info = stat()
            guard lstat(staging, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == ownUID else { continue }
            unlink(staging + "/s")
            if rmdir(staging) == 0 {
                log.notice("removed a staging folder left by an earlier start")
            } else {
                log.error("could not remove a staging folder (errno \(errno))")
            }
        }
    }

    /// Removes a socket file nobody listens on. Only a socket of ours is touched, only after a connect
    /// to it was refused, and only if the file is still the same one right before the unlink. A connect
    /// that is merely slow or blocked counts as a live instance.
    private func replaceStaleSocket() throws {
        var before = stat()
        guard lstat(path, &before) == 0 else { return }
        guard (before.st_mode & S_IFMT) == S_IFSOCK, before.st_uid == ownUID else { throw StartError.occupied(path) }
        switch AppSocket.connect(path: path, timeout: .milliseconds(500)) {
        case .success(let fd):
            close(fd)
            throw StartError.alreadyRunning(path)
        case .failure(.busy):
            throw StartError.alreadyRunning(path)
        case .failure(.failed(let code)):
            throw StartError.system("connect", errno: code)
        case .failure(.invalidPath):
            throw StartError.pathTooLong(path)
        case .failure(.notRunning), .failure(.refused):
            var now = stat()
            guard lstat(path, &now) == 0 else { return }
            guard now.st_dev == before.st_dev, now.st_ino == before.st_ino else { throw StartError.alreadyRunning(path) }
            unlink(path)
        }
    }

    /// Binds the socket where nobody else can reach it, then publishes it. The socket is
    /// bound inside a fresh 0700 folder next to the final path, made 0600, checked (a socket of ours, mode
    /// 0600), put into `listen` mode and only then renamed to the final name without replacing anything
    /// (`RENAME_EXCL`). Nothing can connect before it is private, and no process-wide `umask` is touched
    /// (a tight umask would break files other threads create at that moment). When the temporary path
    /// would not fit a socket address the socket is bound in place and made 0600 at once.
    private func bindPrivateSocket() throws -> Int32 {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var staging = folder + "/.sock-" + String(stagingSuffix(), radix: 16)
        var stagedPath = staging + "/s"
        let useStaging = stagedPath.utf8.count <= AppSocket.maxPathBytes
        if useStaging {
            // A name that is taken (left by something else) is not reused: draw another.
            var made = false
            for _ in 0..<8 {
                if mkdir(staging, 0o700) == 0 {
                    made = true
                    break
                }
                guard errno == EEXIST else { throw StartError.system("mkdir", errno: errno) }
                staging = folder + "/.sock-" + String(stagingSuffix(), radix: 16)
                stagedPath = staging + "/s"
            }
            guard made else { throw StartError.system("mkdir", errno: EEXIST) }
            guard chmod(staging, 0o700) == 0 else {
                let code = errno
                removeStaging(staging)
                throw StartError.system("chmod", errno: code)
            }
        }
        let bindPath = useStaging ? stagedPath : path
        let stagingFolder = staging
        let stagedFile = stagedPath
        func cleanUp() {
            if useStaging {
                unlink(stagedFile)
                removeStaging(stagingFolder)
            } else {
                unlink(path)
            }
        }
        guard var address = AppSocket.address(for: bindPath) else {
            if useStaging { removeStaging(staging) }
            throw StartError.pathTooLong(bindPath)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let code = errno
            if useStaging { removeStaging(staging) }
            throw StartError.system("socket", errno: code)
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bindError = errno
        guard bound == 0 else {
            close(fd)
            if useStaging { removeStaging(staging) }
            throw StartError.system("bind", errno: bindError)
        }
        var info = stat()
        guard lstat(bindPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == ownUID,
              chmod(bindPath, 0o600) == 0
        else {
            close(fd)
            cleanUp()
            throw StartError.occupied(bindPath)
        }
        var checked = stat()
        guard lstat(bindPath, &checked) == 0, checked.st_ino == info.st_ino, checked.st_dev == info.st_dev,
              (checked.st_mode & 0o777) == 0o600, listen(fd, 16) == 0
        else {
            close(fd)
            cleanUp()
            throw StartError.occupied(bindPath)
        }
        if useStaging {
            guard renameExclusive(stagedPath, path) == 0 else {
                let code = errno
                close(fd)
                cleanUp()
                switch code {
                case EEXIST: throw StartError.alreadyRunning(path)
                case ENOTSUP: throw StartError.unsupportedVolume(path)
                default: throw StartError.system("rename", errno: code)
                }
            }
            removeStaging(staging)
        }
        var published = stat()
        guard lstat(path, &published) == 0, published.st_ino == checked.st_ino, published.st_dev == checked.st_dev else {
            close(fd)
            throw StartError.occupied(path)
        }
        boundInode = published.st_ino
        boundDevice = published.st_dev
        return fd
    }

    private func removeStaging(_ staging: String) {
        if rmdir(staging) != 0, errno != ENOENT { log.error("could not remove the staging folder (errno \(errno))") }
    }

    // MARK: - Connections

    private func acceptPending(on listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return }
            // Accepted sockets inherit the listener's non-blocking mode on Darwin.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            AppSocket.setTimeouts(client, receive: requestTimeout, send: requestTimeout)

            let peer = AppSocket.peerUserID(of: client)
            guard AppSocket.allows(peer: peer, own: peerUID) else {
                log.notice("connection from another user refused")
                close(client)
                continue
            }
            let admitted = lock.withLock { () -> Bool in
                guard running < Self.maxConnections else { return false }
                running += 1
                return true
            }
            guard admitted else {
                log.notice("too many connections; one refused")
                close(client)
                continue
            }
            workQueue.async { [self] in
                let slot = Slot { [self] in lock.withLock { running -= 1 } }
                serve(client, slot: slot)
                close(client)
                slot.releaseFromWorker()
            }
        }
    }

    private func serve(_ client: Int32, slot: Slot) {
        let line: Data
        let deadline = ContinuousClock.now + requestTimeout
        switch AppSocket.readLine(from: client, maxBytes: AppSocket.maxRequestBytes, deadline: deadline) {
        case .line(let data): line = data
        case .tooLong:
            log.notice("request line over the limit; connection closed")
            return
        case .timeout, .closed: return
        }
        let response: AppSocketResponse
        if let request = try? JSONDecoder().decode(AppSocketRequest.self, from: line) {
            response = answer(request, slot: slot)
        } else {
            response = AppSocketResponse(id: 0, error: AppSocketError(code: .usage, message: "The request could not be read"))
        }
        guard var out = try? JSONEncoder().encode(response) else { return }
        out.append(0x0A)
        _ = AppSocket.writeAll(out, to: client, deadline: ContinuousClock.now + requestTimeout)
    }

    /// `ping` is answered here, so it says only that the server is alive; everything else goes to the
    /// handler (which runs on the main actor) and is waited for on this worker thread. On a timeout the
    /// caller gets an error and the handler's task is cancelled (it must not act afterwards), but the
    /// connection slot stays taken until that task has really ended, so at most `maxConnections`
    /// handlers exist at once.
    private func answer(_ request: AppSocketRequest, slot: Slot) -> AppSocketResponse {
        if request.method == "ping" { return AppSocketResponse(id: request.id, result: SelectionResult()) }
        let reply = Reply()
        let handler = handler
        slot.handOver()
        let task = Task {
            reply.fulfil(await handler(request))
            slot.releaseFromHandler()
        }
        let (seconds, attoseconds) = handlerTimeout.components
        let limit = DispatchTimeInterval.milliseconds(Int(min(seconds, 1_000_000) * 1000 + attoseconds / 1_000_000_000_000_000))
        if let response = reply.wait(timeout: limit) { return response }
        task.cancel()
        return AppSocketResponse(
            id: request.id, error: AppSocketError(code: .appUnavailable, message: AppSocketClient.timeoutMessage))
    }
}

/// One connection slot. The worker releases it when the connection is done, unless it handed the slot
/// to a handler task, which then releases it when it ends.
private final class Slot: @unchecked Sendable {
    private let lock = NSLock()
    private var handedOver = false
    private var released = false
    private let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }

    func handOver() { lock.withLock { handedOver = true } }

    func releaseFromWorker() {
        let skip = lock.withLock { handedOver }
        if !skip { release() }
    }

    func releaseFromHandler() { release() }

    private func release() {
        let first = lock.withLock { () -> Bool in
            defer { released = true }
            return !released
        }
        if first { onRelease() }
    }
}

/// A one-shot hand-over from a task to the thread waiting for it.
private final class Reply: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: AppSocketResponse?

    func fulfil(_ response: AppSocketResponse) {
        lock.withLock { value = response }
        semaphore.signal()
    }

    func wait(timeout: DispatchTimeInterval) -> AppSocketResponse? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { value }
    }
}
