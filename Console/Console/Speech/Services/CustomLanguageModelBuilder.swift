import Foundation
import Speech

/// Biases Apple's speech recognizer toward Console's domain vocabulary (wake words + trigger phrases)
/// by compiling weighted entries into a `.clm` file via `SFCustomLanguageModelData` (macOS 14.0+).
///
/// This improves recognition of short, specific words like "console" that are otherwise confused with
/// similar-sounding words. The model biases text prediction, not the acoustic model.
///
/// **Lifecycle:** Loads any existing model on init, then rebuilds incrementally when vocabulary changes.
/// On macOS <14, `shared` is nil and callers use optional chaining — no effect on the speech pipeline.
///
/// **Thread safety:** `@MainActor`-isolated. Compilation uses `async` internally via `SFCustomLanguageModelData.export`.
///
/// **Failure behavior:** Failed compilations preserve the previous `compiledModelURL` (stale model > no model).
@Observable
@MainActor
final class CustomLanguageModelBuilder {
    static let shared: CustomLanguageModelBuilder? = {
        if #available(macOS 14.0, *) {
            return CustomLanguageModelBuilder()
        } else {
            return nil
        }
    }()

    private(set) var compiledModelURL: URL?
    private(set) var isCompiling: Bool = false
    private(set) var lastError: Error?

    private var lastVocabularyHash: Int?
    private var rebuildTask: Task<Void, Never>?

    private var modelDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Console", isDirectory: true)
            .appendingPathComponent("CustomLM", isDirectory: true)
    }

    private var compiledModelFileURL: URL {
        modelDirectoryURL.appendingPathComponent("console.clm")
    }

    private init() {
        if #available(macOS 14.0, *) {
            let url = compiledModelFileURL
            if FileManager.default.fileExists(atPath: url.path) {
                compiledModelURL = url
                printDebug("[CustomLM] Loading existing model from disk")
            } else {
                printDebug("[CustomLM] No existing model found")
            }
        }
    }

    // MARK: - Rebuild Orchestration

    /// Debounced entry point for vocabulary changes. Cancels previous pending rebuilds.
    func scheduleRebuild(wakeWords: [String], commands: [Command]) {
        rebuildTask?.cancel()
        printDebug("[CustomLM] Scheduled rebuild (debounced 1.5s)")
        rebuildTask = Task {
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                printDebug("[CustomLM] Rebuild cancelled (superseded by newer request)")
                return
            }
            guard !Task.isCancelled else {
                printDebug("[CustomLM] Rebuild cancelled (superseded by newer request)")
                return
            }
            await rebuildIfNeeded(wakeWords: wakeWords, commands: commands)
        }
    }

    /// Immediate rebuild if vocabulary hash changed. Use for initial build at launch.
    func rebuildIfNeeded(wakeWords: [String], commands: [Command]) async {
        guard #available(macOS 14.0, *) else { return }

        let snapshot = collectVocabulary(wakeWords: wakeWords, commands: commands)
        let hash = snapshot.hashValue

        if hash == lastVocabularyHash {
            printDebug("[CustomLM] Vocabulary unchanged, skipping rebuild (hash: \(hash))")
            return
        }

        if snapshot.wakeWords.isEmpty && snapshot.commandPhrases.isEmpty {
            printDebug("[CustomLM] Skipping build — empty vocabulary")
            return
        }

        isCompiling = true
        printDebug("[CustomLM] Building model — \(snapshot.wakeWords.count) wake words, \(snapshot.commandPhrases.count) command phrases, \(snapshot.individualWords.count) vocabulary words")

        do {
            let url = try await compile(from: snapshot)
            compiledModelURL = url
            lastVocabularyHash = hash
            lastError = nil
        } catch {
            lastError = error
            printDebug("[CustomLM] Compilation failed: \(error)")
        }

        isCompiling = false
    }

    // MARK: - Compilation

    /// Compiles vocabulary into a binary language model file on disk.
    ///
    /// Weight tiers (count = relative frequency hint to the recognizer):
    /// - Wake words: 1000 (highest — activation signal)
    /// - Command phrases: 500 (known command patterns)
    /// - Individual words: 100 (vocabulary hints for partial recognition)
    /// Words appearing as both wake word and command word use the higher weight.
    @available(macOS 14.0, *)
    private func compile(from snapshot: VocabularySnapshot) async throws -> URL {
        let start = CFAbsoluteTimeGetCurrent()

        cleanupExistingModel()

        let modelData = SFCustomLanguageModelData(
            locale: Locale(identifier: "en-US"),
            identifier: "com.console.customlm",
            version: "1"
        )
        let wakeWordSet = Set(snapshot.wakeWords)

        for word in snapshot.wakeWords {
            modelData.insert(phraseCount: .init(phrase: word, count: 1000))
        }

        for phrase in snapshot.commandPhrases {
            modelData.insert(phraseCount: .init(phrase: phrase, count: 500))
        }

        for word in snapshot.individualWords where !wakeWordSet.contains(word) {
            modelData.insert(phraseCount: .init(phrase: word, count: 100))
        }

        try FileManager.default.createDirectory(at: modelDirectoryURL, withIntermediateDirectories: true)
        try await modelData.export(to: compiledModelFileURL)

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        printDebug("[CustomLM] Compilation succeeded in \(elapsed)ms — model at \(compiledModelFileURL.path)")

        return compiledModelFileURL
    }

    private func cleanupExistingModel() {
        let url = compiledModelFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Vocabulary Collection

    struct VocabularySnapshot {
        let wakeWords: [String]
        let commandPhrases: [String]
        let individualWords: Set<String>

        var hashValue: Int {
            var hasher = Hasher()
            for w in wakeWords.sorted() { hasher.combine(w) }
            for p in commandPhrases.sorted() { hasher.combine(p) }
            return hasher.finalize()
        }
    }

    /// Builds a snapshot from raw wake words and commands, lowercasing and extracting individual words.
    func collectVocabulary(
        wakeWords: [String],
        commands: [Command]
    ) -> VocabularySnapshot {
        let loweredWakeWords = wakeWords.map { $0.lowercased() }
        let phrases = commands.flatMap { $0.triggerPhrases }.map { $0.lowercased() }

        var words = Set<String>()
        for w in loweredWakeWords {
            for part in w.split(separator: " ") { words.insert(String(part)) }
        }
        for p in phrases {
            for part in p.split(separator: " ") { words.insert(String(part)) }
        }

        return VocabularySnapshot(
            wakeWords: loweredWakeWords,
            commandPhrases: phrases,
            individualWords: words
        )
    }
}
