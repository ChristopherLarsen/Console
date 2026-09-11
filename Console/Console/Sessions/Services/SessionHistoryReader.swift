import Foundation

/// Background reader for Claude's local transcript history. Enumerates
/// `~/.claude/projects/**/<session-id>.jsonl`, extracts tolerant display
/// metadata, caches it per file (size + modification date), and excludes
/// subagent-only transcripts.
///
/// Everything read here stays local: titles, timestamps, working directories,
/// and branches are display and routing data — never sent to Claude.
@MainActor
final class SessionHistoryReader {
    nonisolated static let claudeProjectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    /// Bounds a first scan: only the most recently modified transcripts are
    /// inspected before the list is shown.
    nonisolated static let maxTranscriptsPerScan = 400
    /// Pathological transcripts are skipped entirely.
    nonisolated static let maxTranscriptByteCount: Int64 = 256 * 1024 * 1024

    struct CachedMetadata: Equatable {
        let byteCount: Int64
        let modified: Date
        let record: SessionHistoryRecord
    }

    private var cache: [String: CachedMetadata] = [:]
    private let ticketAssociations: SessionTicketAssociations

    init(ticketAssociations: SessionTicketAssociations = SessionTicketAssociations()) {
        self.ticketAssociations = ticketAssociations
    }

    /// Loads every resumable transcript, most recently active first. The
    /// heavy scan runs off the main actor; cached files return instantly.
    func loadRecords() async -> [SessionHistoryRecord] {
        let root = Self.claudeProjectsRoot
        let associations = ticketAssociations.allKeys()
        let cached = cache
        let (records, updatedCache) = await Task.detached(priority: .userInitiated) {
            Self.scan(root: root, associations: associations, cache: cached)
        }.value
        cache = updatedCache
        return records
    }

    // MARK: - Scan (off main actor)

    /// Internal so tests can drive a scan against a fixture root.
    nonisolated static func scan(
        root: URL,
        associations: [UUID: String],
        cache: [String: CachedMetadata]
    ) -> ([SessionHistoryRecord], [String: CachedMetadata]) {
        let fileManager = FileManager.default
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return ([], [:])
        }

        var candidates: [(url: URL, byteCount: Int64, modified: Date)] = []
        for projectDir in projectDirs {
            let files = (try? fileManager.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let byteCount = Int64(exactly: values.fileSize ?? 0),
                      byteCount > 0, byteCount <= maxTranscriptByteCount,
                      let modified = values.contentModificationDate else { continue }
                candidates.append((file, byteCount, modified))
            }
        }
        candidates.sort { $0.modified > $1.modified }
        let inspected = candidates.prefix(maxTranscriptsPerScan)

        var updatedCache = cache
        var records: [SessionHistoryRecord] = []
        for candidate in inspected {
            // Canonical key so cache hits survive symlinked temp roots.
            let path = candidate.url.resolvingSymlinksInPath().path
            if let cached = cache[path], cached.byteCount == candidate.byteCount, cached.modified == candidate.modified {
                records.append(cached.record)
                updatedCache[path] = cached
                continue
            }
            guard let metadata = transcriptMetadata(at: candidate.url),
                  let sessionID = UUID(uuidString: candidate.url.deletingPathExtension().lastPathComponent) else {
                updatedCache.removeValue(forKey: path)
                continue
            }
            let record = makeRecord(
                sessionID: sessionID,
                metadata: metadata,
                byteCount: candidate.byteCount,
                modified: candidate.modified,
                associations: associations
            )
            updatedCache[path] = CachedMetadata(
                byteCount: candidate.byteCount, modified: candidate.modified, record: record
            )
            records.append(record)
        }

        records.sort { $0.lastActive > $1.lastActive }
        return (records, updatedCache)
    }

    nonisolated private static func makeRecord(
        sessionID: UUID,
        metadata: TranscriptMetadata,
        byteCount: Int64,
        modified: Date,
        associations: [UUID: String]
    ) -> SessionHistoryRecord {
        let title = [metadata.customTitle, metadata.summary, metadata.firstUserMessage]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Untitled Session"
        let workingDirectory = URL(fileURLWithPath: metadata.lastCWD.isEmpty ? "/" : metadata.lastCWD, isDirectory: true)
        let isCustomTitle = !(metadata.customTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return SessionHistoryRecord(
            claudeSessionID: sessionID,
            title: title,
            lastActive: metadata.lastTimestamp ?? modified,
            workingDirectory: workingDirectory,
            gitBranch: metadata.gitBranch,
            transcriptByteCount: byteCount,
            ticketKey: SessionTicketClassification.ticketKey(
                savedAssociation: associations[sessionID],
                title: title,
                isCustomTitle: isCustomTitle
            ),
            isWorkingDirectoryMissing: !FileManager.default.fileExists(atPath: workingDirectory.path)
        )
    }

    // MARK: - Tolerant JSONL parsing

    struct TranscriptMetadata: Equatable {
        var customTitle: String?
        var summary: String?
        var firstUserMessage: String?
        var lastTimestamp: Date?
        var lastCWD: String = ""
        var gitBranch: String?
        /// False for subagent-only transcripts, which are not resumable
        /// conversations and are excluded from history.
        var hasMainConversation = false
    }

    /// Streams the transcript line by line; malformed lines are skipped.
    /// Returns nil when the transcript holds no resumable conversation.
    nonisolated static func transcriptMetadata(at fileURL: URL) -> TranscriptMetadata? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fileHandle.close() }

        var metadata = TranscriptMetadata()
        var pending = Data()
        let newline = UInt8(ascii: "\n")
        let maxLineLength = 1_000_000

        func consume(_ line: Data) {
            guard line.count <= maxLineLength else { return }
            var trimmed = line
            while trimmed.last == UInt8(ascii: "\r") || trimmed.last == UInt8(ascii: " ") {
                trimmed.removeLast()
            }
            guard !trimmed.isEmpty,
                  let object = (try? JSONSerialization.jsonObject(with: trimmed)) as? [String: Any] else {
                return
            }
            apply(object, to: &metadata)
        }

        while true {
            let chunk: Data
            do { chunk = try fileHandle.read(upToCount: 1 << 20) ?? Data() } catch { break }
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let index = pending.firstIndex(of: newline) {
                let line = pending[pending.startIndex..<index]
                pending.removeSubrange(pending.startIndex...index)
                consume(line)
            }
            if pending.count > maxLineLength { pending.removeAll(keepingCapacity: false) }
        }
        if !pending.isEmpty { consume(pending) }

        guard metadata.hasMainConversation else { return nil }
        return metadata
    }

    nonisolated private static func apply(_ object: [String: Any], to metadata: inout TranscriptMetadata) {
        if metadata.customTitle == nil {
            for key in ["title", "customTitle", "sessionTitle"] {
                if let title = object[key] as? String,
                   !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    metadata.customTitle = title
                    break
                }
            }
        }
        if object["type"] as? String == "summary", metadata.summary == nil,
           let summary = object["summary"] as? String,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata.summary = summary
        }

        let isSidechain = object["isSidechain"] as? Bool == true
        if !isSidechain, object["isMeta"] as? Bool != true,
           ["user", "assistant"].contains(object["type"] as? String) {
            metadata.hasMainConversation = true
            if metadata.firstUserMessage == nil, object["type"] as? String == "user",
               let text = userMessageText(from: object["message"]),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                metadata.firstUserMessage = text
            }
        }

        if let cwd = object["cwd"] as? String, !cwd.isEmpty { metadata.lastCWD = cwd }
        if let branch = object["gitBranch"] as? String, !branch.isEmpty { metadata.gitBranch = branch }
        if let timestamp = object["timestamp"] as? String, let date = decodeTimestamp(timestamp),
           metadata.lastTimestamp.map({ date > $0 }) ?? true {
            metadata.lastTimestamp = date
        }
    }

    /// First user prompt text: a plain string content or concatenated text
    /// blocks. Tool results and non-text blocks contribute nothing.
    nonisolated static func userMessageText(from message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return collapseWhitespace(text) }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
            return collapseWhitespace(text)
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    nonisolated private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// Claude timestamps are ISO-8601, usually with fractional seconds.
    nonisolated static func decodeTimestamp(_ string: String) -> Date? {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        if let date = try? fractional.parse(string) { return date }
        return try? plain.parse(string)
    }
}
