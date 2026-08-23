import Foundation

/// A subset of GitHub's documented Release payload fields.
/// https://docs.github.com/en/rest/releases/releases?apiVersion=latest
nonisolated struct GitHubRelease: Hashable, Decodable, Sendable {

    let tagName: String
    let name: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case draft
        case prerelease
        case htmlURL = "html_url"
    }

    /// Strict semantic version of `tag_name`, if it parses.
    var semanticVersion: SemanticVersion? { SemanticVersion.parse(tagName) }
}

// MARK: - Qualification

extension GitHubRelease {

    /// Published (non-draft, non-prerelease) releases with a valid semantic
    /// version tag, sorted highest version first.
    static func qualifyingCandidates(in releases: [GitHubRelease]) -> [GitHubRelease] {
        releases
            .filter { !$0.draft && !$0.prerelease && $0.semanticVersion != nil }
            .sorted {
                guard let lhs = $0.semanticVersion, let rhs = $1.semanticVersion else { return false }
                return lhs > rhs
            }
    }

    /// The highest published release whose `(major, minor)` is newer than the
    /// running app's. Patch-only and build-number changes never qualify.
    static func qualifyingUpdate(from current: SemanticVersion, in releases: [GitHubRelease]) -> GitHubRelease? {
        let currentTuple = (current.major, current.minor)
        return qualifyingCandidates(in: releases).first { candidate in
            guard let version = candidate.semanticVersion else { return false }
            return (version.major, version.minor) > currentTuple
        }
    }
}

// MARK: - Errors

enum UpdateError: LocalizedError, Equatable {
    case badResponse
    case httpStatus(Int)
    case decoding(String)
    case offline
    case rateLimited
    case repositoryUnavailable

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "The update server returned an unexpected response."
        case .httpStatus(let code):
            return "The update server returned HTTP \(code)."
        case .decoding:
            return "The update server returned data Console could not read."
        case .offline:
            return "Console is offline. Check your network connection and try again."
        case .rateLimited:
            return "GitHub rate-limited this check. Wait a minute and try again."
        case .repositoryUnavailable:
            return "The Console releases repository is not publicly readable."
        }
    }
}

// MARK: - Client

protocol GitHubReleaseFetching: Sendable {
    func fetchReleases() async throws -> [GitHubRelease]
}

/// Fetches public GitHub Releases for the Console repository.
/// No credentials are embedded or required; the endpoint is public.
struct GitHubReleaseClient: GitHubReleaseFetching {

    nonisolated static let defaultEndpoint = URL(
        string: "https://api.github.com/repos/ChristopherLarsen/Console/releases"
    )!

    private let session: URLSession
    private let endpoint: URL

    nonisolated init(session: URLSession = .shared, endpoint: URL = GitHubReleaseClient.defaultEndpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    func fetchReleases() async throws -> [GitHubRelease] {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.isOffline(error) {
            throw UpdateError.offline
        }

        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        switch http.statusCode {
        case 200..<300:
            break
        case 404:
            throw UpdateError.repositoryUnavailable
        case 403, 429:
            throw UpdateError.rateLimited
        default:
            throw UpdateError.httpStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode([GitHubRelease].self, from: data)
        } catch {
            throw UpdateError.decoding(error.localizedDescription)
        }
    }

    private static func isOffline(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}
