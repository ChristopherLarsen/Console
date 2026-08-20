import Foundation

/// Intelligently strips wake words from transcribed speech to extract the actual command.
struct WakeWordStripper {
    /// Common filler words that might appear between wake word and command
    private static let fillerWords: Set<String> = [
        "please", "can", "you", "could", "would", "will",
        "i", "want", "need", "to", "the", "a", "an"
    ]

    /// Strips the wake word (and everything before it) from the transcribed text.
    /// Returns just the command portion.
    ///
    /// Examples:
    /// - Input: "console open terminal", Wake: "console" → Output: "open terminal"
    /// - Input: "console please open terminal", Wake: "console" → Output: "open terminal"
    /// - Input: "okay console turn on the lights", Wake: "console" → Output: "turn on the lights"
    /// - Input: "console can you open safari", Wake: "console" → Output: "open safari"
    ///
    /// - Parameters:
    ///   - transcribedText: The full transcribed speech
    ///   - wakeWord: The wake word that was detected (e.g., "console", "hey console")
    ///   - wakeWords: All configured wake words (for multi-word matching)
    /// - Returns: The command portion with wake word and fillers removed
    static func stripWakeWord(
        from transcribedText: String,
        detectedWakeWord: String,
        allWakeWords: [String] = []
    ) -> String {
        let normalized = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        // Split into words for analysis
        let words = normalized.split(separator: " ").map { String($0) }
        guard !words.isEmpty else { return normalized }

        // Find the position where the wake word ends
        let wakeWordEndIndex = findWakeWordEndIndex(
            words: words,
            detectedWakeWord: detectedWakeWord,
            allWakeWords: allWakeWords
        )

        guard wakeWordEndIndex < words.count else {
            // Wake word was the only thing said
            return ""
        }

        // Extract words after wake word
        var commandWords = Array(words[wakeWordEndIndex...])

        // Strip leading filler words
        commandWords = stripLeadingFillers(commandWords)

        // Rejoin and return
        let command = commandWords.joined(separator: " ")
        return command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds the index after the last wake word occurrence
    private static func findWakeWordEndIndex(
        words: [String],
        detectedWakeWord: String,
        allWakeWords: [String]
    ) -> Int {
        // Normalize all wake words to lowercase and split multi-word wake words
        let normalizedWakeWords = ([detectedWakeWord] + allWakeWords)
            .map { $0.lowercased().split(separator: " ").map { String($0) } }

        // Find the last occurrence of any wake word pattern
        var lastMatchEndIndex = 0

        for i in 0..<words.count {
            let word = words[i].lowercased()

            // Check single-word wake words first
            for wakeWordParts in normalizedWakeWords where wakeWordParts.count == 1 {
                if word == wakeWordParts[0] {
                    lastMatchEndIndex = i + 1
                }
            }

            // Check multi-word wake words (e.g., "hey console")
            for wakeWordParts in normalizedWakeWords where wakeWordParts.count > 1 {
                if i + wakeWordParts.count <= words.count {
                    let slice = words[i..<(i + wakeWordParts.count)].map { $0.lowercased() }
                    if slice == wakeWordParts {
                        lastMatchEndIndex = i + wakeWordParts.count
                    }
                }
            }
        }

        return lastMatchEndIndex
    }

    /// Strips common filler words from the beginning of the command
    static func stripLeadingFillers(_ words: [String]) -> [String] {
        var result = words

        // Remove filler words from the start
        while !result.isEmpty {
            let firstWord = result[0].lowercased()
            if fillerWords.contains(firstWord) {
                result.removeFirst()
            } else {
                break
            }
        }

        return result
    }

    /// Quick check if text likely contains a wake word (useful for pre-validation)
    static func containsWakeWord(_ text: String, wakeWords: [String]) -> Bool {
        let normalized = text.lowercased()
        return wakeWords.contains { wakeWord in
            normalized.contains(wakeWord.lowercased())
        }
    }
}

