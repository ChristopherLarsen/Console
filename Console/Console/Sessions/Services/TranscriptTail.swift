import Foundation

/// Reads the last assistant text replies from a Claude Code transcript
/// (`~/.claude/projects/<project>/<session-id>.jsonl`). Read-only; used for
/// Orchestrator relay notes. ConsoleTermBridge keeps a copy of the same
/// parsing for the `read_console_session_output` tool.
nonisolated enum TranscriptTail {
    static let defaultProjectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    /// Only the file's tail is read so long transcripts stay cheap.
    static let tailBytes = 512 * 1024

    static func lastAssistantMessages(
        claudeSessionID: UUID,
        count: Int,
        projectsRoot: URL = defaultProjectsRoot
    ) -> [String] {
        guard count > 0, let url = transcriptURL(claudeSessionID: claudeSessionID, projectsRoot: projectsRoot),
              let text = readTail(of: url) else { return [] }
        return lastAssistantMessages(inJSONL: text, count: count)
    }

    static func transcriptURL(claudeSessionID: UUID, projectsRoot: URL) -> URL? {
        let fileName = "\(claudeSessionID.uuidString.lowercased()).jsonl"
        let fileManager = FileManager.default
        guard let projects = try? fileManager.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        for project in projects {
            for name in [fileName, "\(claudeSessionID.uuidString).jsonl"] {
                let candidate = project.appendingPathComponent(name)
                if fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    static func lastAssistantMessages(inJSONL text: String, count: Int) -> [String] {
        var replies: [String] = []
        for line in text.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            let reply = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else { continue }
            replies.append(reply)
            if replies.count == count { break }
        }
        return replies.reversed()
    }

    private static func readTail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // Drop a partial first line when reading from mid-file.
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }
}
