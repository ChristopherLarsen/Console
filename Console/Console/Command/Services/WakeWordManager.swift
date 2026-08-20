import Foundation
import SwiftData

@Observable
@MainActor
final class WakeWordManager {
    private var modelContext: ModelContext

    private(set) var wakeWords: [WakeWord] = []
    var onVocabularyChanged: (() -> Void)?

    var enabledWords: [String] {
        wakeWords.filter(\.isEnabled).map(\.word)
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        fetchWakeWords()
        seedDefaultsIfNeeded()
    }

    func fetchWakeWords() {
        let descriptor = FetchDescriptor<WakeWord>(sortBy: [SortDescriptor(\.createdAt)])
        wakeWords = (try? modelContext.fetch(descriptor)) ?? []
    }

    func addWakeWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let existing = wakeWords.contains { $0.word.lowercased() == trimmed.lowercased() }
        guard !existing else { return }

        let wakeWord = WakeWord(word: trimmed)
        modelContext.insert(wakeWord)
        saveAndRefresh()
        onVocabularyChanged?()
    }

    func deleteWakeWord(_ wakeWord: WakeWord) -> Bool {
        let enabledCount = wakeWords.filter(\.isEnabled).count
        if wakeWord.isEnabled && enabledCount <= 1 {
            return false
        }
        modelContext.delete(wakeWord)
        saveAndRefresh()
        onVocabularyChanged?()
        return true
    }

    @discardableResult
    func toggleWakeWord(_ wakeWord: WakeWord) -> Bool {
        if wakeWord.isEnabled {
            let enabledCount = wakeWords.filter(\.isEnabled).count
            guard enabledCount > 1 else { return false }
        }
        wakeWord.isEnabled.toggle()
        saveAndRefresh()
        onVocabularyChanged?()
        return true
    }

    private func seedDefaultsIfNeeded() {
        guard wakeWords.isEmpty else { return }
        let defaults = ["Console"]
        for word in defaults {
            let wakeWord = WakeWord(word: word)
            modelContext.insert(wakeWord)
        }
        saveAndRefresh()
        onVocabularyChanged?()
    }

    private func saveAndRefresh() {
        do {
            try modelContext.save()
        } catch {
            printDebug("[Console] Failed to persist wake word changes: \(error)")
        }
        fetchWakeWords()
    }
}
