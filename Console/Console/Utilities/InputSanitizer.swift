import Foundation

struct InputSanitizer {

    // MARK: - Command Name
    // Allow: letters, numbers, spaces, hyphens, underscores, apostrophes, periods

    static func commandName(_ input: String) -> String {
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: " -_'."))
        return filter(input, allowed: allowed, maxLength: 100)
    }

    // MARK: - Command Phrase
    // Allow: letters, numbers, spaces, hyphens, apostrophes, commas

    static func commandPhrase(_ input: String) -> String {
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: " -',"))
        return filter(input, allowed: allowed, maxLength: 200)
    }

    // MARK: - Command Description (sent to LLM)
    // Allow: letters, numbers, spaces, common punctuation, newlines

    static func commandDescription(_ input: String) -> String {
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespaces)
            .union(.newlines)
            .union(CharacterSet(charactersIn: ".,!?-'()/:\""))
        return filter(input, allowed: allowed, maxLength: 500)
    }

    // MARK: - Search Query
    // Allow: letters, numbers, spaces, hyphens

    static func searchQuery(_ input: String) -> String {
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: " -"))
        return filter(input, allowed: allowed, maxLength: 100)
    }

    // MARK: - Trigger Word
    // Allow: letters, numbers, spaces, hyphens

    static func triggerWord(_ input: String) -> String {
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: " -"))
        return filter(input, allowed: allowed, maxLength: 30)
    }

    // MARK: - Authorization Words
    // Allow: letters, numbers, spaces, commas, hyphens

    static func authorizationWords(_ input: String) -> String {
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: " ,-"))
        return filter(input, allowed: allowed, maxLength: 200)
    }

    // MARK: - Endpoint URL
    // Allow: standard URL characters

    static func endpointURL(_ input: String) -> String {
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: ":/.\\-_?&=%+@"))
        return filter(input, allowed: allowed, maxLength: 500)
    }

    // MARK: - Model Name
    // Allow: letters, numbers, hyphens, underscores, periods, colons, slashes

    static func modelName(_ input: String) -> String {
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "-_.:/"))
        return filter(input, allowed: allowed, maxLength: 100)
    }

    // MARK: - Private

    private static func filter(_ input: String, allowed: CharacterSet, maxLength: Int) -> String {
        let filtered = String(input.unicodeScalars.filter { allowed.contains($0) })
        if filtered.count > maxLength {
            return String(filtered.prefix(maxLength))
        }
        return filtered
    }
}
