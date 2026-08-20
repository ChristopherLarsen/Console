import Foundation

struct CommandMatch {
    let command: Command
    let triggerPhrase: String
    let confidence: Double
}

@MainActor
final class CommandMatcher {
    private let confidenceThreshold: Double

    nonisolated init(confidenceThreshold: Double = 0.75) {
        self.confidenceThreshold = confidenceThreshold
    }

    func findMatches(for input: String, in commands: [Command]) -> [CommandMatch] {
        let normalizedInput = normalize(input)
        var matches: [CommandMatch] = []

        for command in commands where command.isEnabled {
            for phrase in command.triggerPhrases {
                let normalizedPhrase = normalize(phrase)
                let confidence = calculateConfidence(input: normalizedInput, phrase: normalizedPhrase)

                if confidence >= confidenceThreshold {
                    matches.append(CommandMatch(
                        command: command,
                        triggerPhrase: phrase,
                        confidence: confidence
                    ))
                }
            }
        }

        return matches.sorted { $0.confidence > $1.confidence }
    }

    func bestMatch(for input: String, in commands: [Command]) -> CommandMatch? {
        let matches = findMatches(for: input, in: commands)
        guard !matches.isEmpty else { return nil }

        // Deduplicate by command name so duplicate entries don't trigger the ambiguity guard
        let uniqueCommandNames = Set(matches.map { $0.command.name })
        guard uniqueCommandNames.count == 1 else { return nil }

        return matches.first
    }

    // MARK: - Confidence Scoring

    nonisolated func calculateConfidence(input: String, phrase: String) -> Double {
        if input == phrase { return 1.0 }

        let containsScore = containsMatchScore(input: input, phrase: phrase)
        let editScore = editDistanceScore(input: input, phrase: phrase)
        let tokenScore = tokenOverlapScore(input: input, phrase: phrase)

        // Weighted combination
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

    // MARK: - Levenshtein Distance

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

    // MARK: - Normalization

    nonisolated func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .punctuationCharacters)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
