import Foundation

struct ConsoleCommandMatch {
    let command: ConsoleCommand
    let triggerPhrase: String
    let confidence: Double
}

@MainActor
struct ConsoleCommandMatcher {
    private let confidenceThreshold: Double

    init(confidenceThreshold: Double = 0.75) {
        self.confidenceThreshold = confidenceThreshold
    }

    /// Find the best matching Console command, filtered by availability and context
    func bestMatch(
        for input: String,
        availableIn mode: ModePriority?
    ) -> ConsoleCommandMatch? {
        let matches = findMatches(for: input, availableIn: mode)
        guard !matches.isEmpty else { return nil }

        // Keep the highest-confidence match per command id so duplicate
        // phrases don't trigger the ambiguity guard.
        var bestPerID: [String: ConsoleCommandMatch] = [:]
        for match in matches {
            if let existing = bestPerID[match.command.id], existing.confidence >= match.confidence {
                continue
            }
            bestPerID[match.command.id] = match
        }
        let candidates = bestPerID.values.sorted { $0.confidence > $1.confidence }

        // A strictly lower-scoring runner-up is not ambiguity — the clear
        // winner wins. Equal top scores across distinct commands stay ambiguous.
        if candidates.count > 1, candidates[0].confidence == candidates[1].confidence {
            return nil
        }
        return candidates.first
    }

    /// Find all matching Console commands, filtered by availability and context
    func findMatches(
        for input: String,
        availableIn mode: ModePriority?
    ) -> [ConsoleCommandMatch] {
        let normalizedInput = normalize(input)
        var matches: [ConsoleCommandMatch] = []

        for command in ConsoleCommandRegistry.all {
            // Check mode availability
            if let requiredMode = command.availableIn, requiredMode != mode {
                continue
            }

            // Check contextual requirements (e.g., isEditMode for note commands)
            if let check = command.contextualCheck, !check() {
                continue
            }

            // Fuzzy match trigger phrases
            for phrase in command.triggerPhrases {
                let normalizedPhrase = normalize(phrase)
                let confidence = calculateConfidence(input: normalizedInput, phrase: normalizedPhrase)

                if confidence >= confidenceThreshold {
                    matches.append(ConsoleCommandMatch(
                        command: command,
                        triggerPhrase: phrase,
                        confidence: confidence
                    ))
                }
            }
        }

        return matches.sorted { $0.confidence > $1.confidence }
    }

    /// Confidence scoring — identical algorithm to CommandMatcher
    nonisolated func calculateConfidence(input: String, phrase: String) -> Double {
        if input == phrase { return 1.0 }

        let containsScore = containsMatchScore(input: input, phrase: phrase)
        let editScore = editDistanceScore(input: input, phrase: phrase)
        let tokenScore = tokenOverlapScore(input: input, phrase: phrase)

        // Weighted combination (same as CommandMatcher)
        return (containsScore * 0.4) + (editScore * 0.3) + (tokenScore * 0.3)
    }

    nonisolated private func containsMatchScore(input: String, phrase: String) -> Double {
        if input.contains(phrase) || phrase.contains(input) { return 0.9 }
        return 0.0
    }

    nonisolated private func editDistanceScore(input: String, phrase: String) -> Double {
        let distance = levenshteinDistance(input, phrase)
        let maxLen = max(input.count, phrase.count)
        guard maxLen > 0 else { return 1.0 }
        let normalized = 1.0 - (Double(distance) / Double(maxLen))
        return max(0.0, normalized)
    }

    nonisolated private func tokenOverlapScore(input: String, phrase: String) -> Double {
        let inputTokens = Set(input.split(separator: " ").map { String($0) })
        let phraseTokens = Set(phrase.split(separator: " ").map { String($0) })

        guard !phraseTokens.isEmpty else { return 0.0 }

        let intersection = inputTokens.intersection(phraseTokens)
        return Double(intersection.count) / Double(phraseTokens.count)
    }

    nonisolated private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count
        let n = b.count

        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            prev = curr
        }

        return prev[n]
    }

    nonisolated private func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .punctuationCharacters)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
