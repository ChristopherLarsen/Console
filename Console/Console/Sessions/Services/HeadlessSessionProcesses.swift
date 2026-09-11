import Darwin
import Foundation

/// PID plus kernel start time: a recycled PID must never become a kill target.
nonisolated struct SessionProcessIdentity: Codable, Equatable, Hashable, Sendable {
    let pid: Int32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
}

nonisolated struct SessionProcessSnapshot: Equatable, Sendable {
    let identity: SessionProcessIdentity
    let parentPID: Int32
    let claudeSessionID: UUID?
    let isConsoleOwned: Bool
}

struct HeadlessSession: Identifiable, Equatable {
    var id: SessionProcessIdentity { process.identity }
    let record: SessionRestorationRecord
    let process: SessionProcessSnapshot
}

nonisolated protocol SessionProcessInspecting: Sendable {
    func snapshot() throws -> [SessionProcessSnapshot]
    func isRunning(_ identity: SessionProcessIdentity) -> Bool
    func signal(_ signal: Int32, to identity: SessionProcessIdentity) throws
}

/// Native, local-only inspection. Never logs or retains process environments.
nonisolated struct HeadlessSessionProcesses: SessionProcessInspecting {
    static let sessionEnvironmentKey = "CONSOLE_SESSION_CLAUDE_ID"

    func snapshot() throws -> [SessionProcessSnapshot] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { throw POSIXError(.EIO) }
        var pids = [Int32](repeating: 0, count: Int(count) / MemoryLayout<Int32>.size + 256)
        let capacity = Int32(pids.count * MemoryLayout<Int32>.size)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, capacity) }
        guard bytes > 0, bytes < capacity else { throw POSIXError(.EIO) }
        return pids.prefix(Int(bytes) / MemoryLayout<Int32>.size).compactMap { pid in
            guard pid > 1, let info = Self.info(pid), info.pbi_uid == getuid(), info.pbi_status != SZOMB else { return nil }
            let session = Self.arguments(pid).flatMap {
                Self.classify(arguments: $0.arguments, executable: $0.executable, marker: $0.marker)
            }
            guard let after = Self.info(pid), Self.identity(after) == Self.identity(info) else { return nil }
            return SessionProcessSnapshot(identity: Self.identity(info), parentPID: Int32(after.pbi_ppid),
                                          claudeSessionID: session?.id, isConsoleOwned: session?.owned ?? false)
        }
    }

    func isRunning(_ identity: SessionProcessIdentity) -> Bool {
        guard let info = Self.info(identity.pid) else { return false }
        return info.pbi_status != SZOMB && Self.identity(info) == identity
    }

    static func identity(for pid: Int32) -> SessionProcessIdentity? {
        guard pid > 1, let info = info(pid), info.pbi_uid == getuid(), info.pbi_status != SZOMB else { return nil }
        return identity(info)
    }

    func signal(_ signal: Int32, to identity: SessionProcessIdentity) throws {
        guard let info = Self.info(identity.pid), Self.identity(info) == identity,
              info.pbi_uid == getuid(), info.pbi_ppid == 1, info.pbi_status != SZOMB else {
            throw POSIXError(.ESRCH)
        }
        guard Darwin.kill(identity.pid, signal) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func classify(arguments: [String], executable: String, marker: String?) -> (id: UUID, owned: Bool)? {
        let isClaude = URL(fileURLWithPath: executable).lastPathComponent == "claude"
            || executable.contains("/claude/versions/")
            || arguments.first == "claude"
            || arguments.dropFirst().first?.hasSuffix("/@anthropic-ai/claude-code/cli.js") == true
        guard isClaude else { return nil }
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let argumentID = (value(after: "--session-id") ?? value(after: "--resume")).flatMap(UUID.init(uuidString:))
        let markerID = marker.flatMap(UUID.init(uuidString:))
        guard let id = argumentID ?? markerID else { return nil }
        // Legacy Console launches already carry an ephemeral Console plugin path.
        let legacyPlugin = value(after: "--plugin-dir").map { path in
            URL(fileURLWithPath: path).pathComponents.contains { component in
                component.hasPrefix("console-sessions-")
                    && UUID(uuidString: String(component.dropFirst("console-sessions-".count))) != nil
            }
        } ?? false
        return (id, markerID == id || legacyPlugin)
    }

    private static func info(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func identity(_ info: proc_bsdinfo) -> SessionProcessIdentity {
        .init(pid: Int32(info.pbi_pid), startedSeconds: info.pbi_start_tvsec,
              startedMicroseconds: info.pbi_start_tvusec)
    }

    private static func arguments(_ pid: Int32) -> (executable: String, arguments: [String], marker: String?)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 4 * 1024 * 1024 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        return decodeArguments(Array(buffer.prefix(size)))
    }

    static func decodeArguments(_ buffer: [UInt8]) -> (executable: String, arguments: [String], marker: String?)? {
        guard buffer.count > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 65536 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        func next() -> String? {
            guard cursor < buffer.count, let end = buffer[cursor...].firstIndex(of: 0) else { return nil }
            defer { cursor = end + 1 }
            return String(bytes: buffer[cursor..<end], encoding: .utf8)
        }
        guard let executable = next() else { return nil }
        while cursor < buffer.count && buffer[cursor] == 0 { cursor += 1 }
        var args: [String] = []
        for _ in 0..<argc {
            guard let arg = next() else { return nil }
            args.append(arg)
        }
        var marker: String?
        while let entry = next(), !entry.isEmpty {
            if entry.hasPrefix(sessionEnvironmentKey + "=") {
                marker = String(entry.dropFirst(sessionEnvironmentKey.count + 1))
            }
        }
        return (executable, args, marker)
    }
}
