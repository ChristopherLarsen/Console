import Foundation

/// Strict semantic version supporting only `X.Y.Z` and `vX.Y.Z` tags.
///
/// Malformed tags are rejected: missing components (`1.2`), extra components
/// (`1.2.3.4`), leading zeros (`01.2.3`), any whitespace, pre-release suffixes
/// (`1.2.3-beta`) and build metadata (`1.2.3+5`).
nonisolated struct SemanticVersion: Hashable, Comparable, CustomStringConvertible, Sendable {

    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses a strict `X.Y.Z` or `vX.Y.Z` tag. Returns nil for anything else.
    static func parse(_ raw: String) -> SemanticVersion? {
        guard !raw.isEmpty else { return nil }

        // Any whitespace anywhere disqualifies the tag.
        if raw.contains(where: \.isWhitespace) { return nil }

        // Only a lowercase "v" prefix is accepted ("V1.2.3" is malformed).
        let body = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        guard !body.isEmpty else { return nil }

        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        guard let major = component(parts[0]),
              let minor = component(parts[1]),
              let patch = component(parts[2]) else { return nil }

        return SemanticVersion(major: major, minor: minor, patch: patch)
    }

    var displayString: String { "\(major).\(minor).\(patch)" }
    var description: String { displayString }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// A numeric release component: exactly "0", or digits without a leading zero.
    private static func component(_ part: Substring) -> Int? {
        guard part.isEmpty == false else { return nil }
        if part.count > 1 && part.first == "0" { return nil }
        guard part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(part)
    }
}
