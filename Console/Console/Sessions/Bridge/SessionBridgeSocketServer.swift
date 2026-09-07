import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Low-level Unix-domain socket listener for the Console bridge.
///
/// Runs entirely off the main actor on a private serial queue. Accepted and
/// validated lines are delivered to a main-thread callback. No HTTP, no TCP.
nonisolated final class SessionBridgeSocketServer: @unchecked Sendable {
    /// Contract: 8 KiB maximum envelope including the trailing newline, so a
    /// line body may carry at most one byte less.
    static let maxLineBytes = BridgeProtocol.maxEnvelopeBytes - 1
    /// A same-uid peer that connects and withholds data must not monopolize
    /// the serial accept loop; idle reads fail closed after this long.
    static let clientReadTimeout: TimeInterval = 5

    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "console.bridge.socket", qos: .userInitiated)
    private let socketPath: String
    private let deliver: @Sendable (Data) -> Void

    init(socketPath: String, deliver: @escaping @Sendable (Data) -> Void) {
        self.socketPath = socketPath
        self.deliver = deliver
    }

    /// Picks a short protected location for the socket. Unix-domain socket
    /// paths are limited to 104 bytes (`sun_path`), and the per-user temp
    /// directory alone can exceed that, so fall back to a private directory
    /// under /private/tmp created with mode 0700.
    nonisolated static func makeProtectedSocketURL() -> URL? {
        let fm = FileManager.default
        let suffix = UUID().uuidString.prefix(8)
        var candidates: [String] = [
            NSTemporaryDirectory(),
            "/private/tmp/",
            "/tmp/",
        ]
        candidates = candidates.map { ($0 as NSString).appendingPathComponent("cbridge-\(suffix)") }
        for candidate in candidates {
            let socketPath = candidate + "/s.sock"
            guard socketPath.utf8CString.count - 1 <= 100 else { continue }
            do {
                try fm.createDirectory(atPath: candidate, withIntermediateDirectories: true)
                try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: candidate)
                return URL(fileURLWithPath: socketPath)
            } catch {
                continue
            }
        }
        return nil
    }

    /// Creates the protected ephemeral directory and binds the socket.
    /// Returns false when the listener could not start (instrumentation then
    /// reports Unknown; Claude remains fully usable).
    func start() -> Bool {
        let dir = (socketPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        try? fm.removeItem(atPath: socketPath)
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: dir
            )
        } catch {
            return false
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { destination in
            let destinationPointer = destination.baseAddress!.assumingMemoryBound(to: CChar.self)
            _ = socketPath.withCString { source in
                strlcpy(destinationPointer, source, destination.count)
            }
        }

        let bound: Bool = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound else {
            close(fd)
            return false
        }
        // Explicit 0700 on the socket inode; the directory mode alone would
        // leave the socket itself on umask defaults.
        guard chmod(socketPath, 0o700) == 0 else {
            close(fd)
            return false
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            return false
        }

        listenFD = fd
        queue.async { [weak self] in
            self?.acceptLoop()
        }
        return true
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.listenFD >= 0 else { return }
            Darwin.close(self.listenFD)
            self.listenFD = -1
            try? FileManager.default.removeItem(atPath: self.socketPath)
        }
    }

    // MARK: - Internals

    private func acceptLoop() {
        while listenFD >= 0 {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(listenFD, &addr, &len)
            if clientFD < 0 {
                if errno == EINTR { continue }
                return
            }
            handle(clientFD: clientFD)
        }
    }

    /// Reads newline-delimited envelopes from one connection, verifying the
    /// peer belongs to the current user, until EOF, error, or an idle read
    /// timeout. The timeout keeps a stalled same-uid peer from blocking the
    /// serial accept loop for every other session's helper.
    private func handle(clientFD: Int32) {
        defer { Darwin.close(clientFD) }

        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(clientFD, &uid, &gid) == 0, uid == getuid() else {
            return
        }

        var timeout = timeval()
        timeout.tv_sec = Int(Self.clientReadTimeout)
        _ = setsockopt(
            clientFD,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var buffer = [UInt8](repeating: 0, count: Self.maxLineBytes * 2)
        var line = [UInt8]()
        while true {
            let n = read(clientFD, &buffer, buffer.count)
            if n <= 0 {
                return
            }
            for index in 0..<n {
                let byte = buffer[index]
                if byte == UInt8(ascii: "\n") {
                    emit(line)
                    line.removeAll(keepingCapacity: true)
                    if line.capacity > Self.maxLineBytes {
                        line.reserveCapacity(Self.maxLineBytes)
                    }
                } else {
                    line.append(byte)
                }
                if line.count > Self.maxLineBytes {
                    // Oversized envelope: drop the connection.
                    return
                }
            }
        }
    }

    private func emit(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, bytes.count <= Self.maxLineBytes else { return }
        deliver(Data(bytes))
    }
}
