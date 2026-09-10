import Foundation

/// Outcome of one extraction pass over a page the active code host has
/// already rendered. Never carries extracted content in its descriptions.
enum MergeRequestListExtractionResult: Equatable {
    case items([MergeRequestSummary])
    case empty
    case authenticationRequired
    case unsupportedPage
}

extension MergeRequestListExtractionResult: CustomStringConvertible, CustomDebugStringConvertible {
    private var redactedName: String {
        switch self {
        case .items(let items): return "items(\(items.count))"
        case .empty: return "empty"
        case .authenticationRequired: return "authenticationRequired"
        case .unsupportedPage: return "unsupportedPage"
        }
    }

    var description: String { redactedName }
    var debugDescription: String { redactedName }
}

enum MergeRequestListExtractorError: Error {
    case invalidPayload
}

/// Turns the JSON produced by a host-specific extractor script (run against
/// the already-rendered list DOM via `WebPage.callJavaScript`) into typed,
/// deduplicated, order-preserving summaries.
///
/// Identity is the normalized absolute MR URL — never the IID alone, which is
/// only unique within one project.
enum MergeRequestListExtractor {

    // MARK: - JSON payload

    private struct Payload: Decodable {
        enum CodingKeys: String, CodingKey {
            case outcome
            case rows = "items"
        }

        let outcome: String
        let rows: [Row]
    }

    struct Row: Decodable, Equatable, Sendable {
        enum CodingKeys: String, CodingKey {
            case url
            case iid
            case title
            case project
            case author
            case isDraft
            case pipeline
            case review
            case target
            case updated
        }

        var url: String?
        var iid: String?
        var title: String?
        var project: String?
        var author: String?
        var isDraft: Bool
        var pipeline: String?
        var review: String?
        var target: String?
        var updated: String?

        init(
            url: String? = nil,
            iid: String? = nil,
            title: String? = nil,
            project: String? = nil,
            author: String? = nil,
            isDraft: Bool = false,
            pipeline: String? = nil,
            review: String? = nil,
            target: String? = nil,
            updated: String? = nil
        ) {
            self.url = url
            self.iid = iid
            self.title = title
            self.project = project
            self.author = author
            self.isDraft = isDraft
            self.pipeline = pipeline
            self.review = review
            self.target = target
            self.updated = updated
        }

        /// Tolerant decoding: absent fields stay nil/false so a partially
        /// rendered row from a different host version cannot invalidate the
        /// whole list payload.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            iid = try container.decodeIfPresent(String.self, forKey: .iid)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            project = try container.decodeIfPresent(String.self, forKey: .project)
            author = try container.decodeIfPresent(String.self, forKey: .author)
            isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
            pipeline = try container.decodeIfPresent(String.self, forKey: .pipeline)
            review = try container.decodeIfPresent(String.self, forKey: .review)
            target = try container.decodeIfPresent(String.self, forKey: .target)
            updated = try container.decodeIfPresent(String.self, forKey: .updated)
        }
    }

    // MARK: - Decoding

    /// Decodes an extractor payload string. Rows without a valid absolute MR
    /// URL or without a usable title are dropped; duplicates collapse onto the
    /// first occurrence while preserving DOM order.
    static func decode(_ json: String) throws -> MergeRequestListExtractionResult {
        guard let data = json.data(using: .utf8) else { throw MergeRequestListExtractorError.invalidPayload }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw MergeRequestListExtractorError.invalidPayload
        }

        switch payload.outcome {
        case "authenticationRequired":
            return .authenticationRequired
        case "empty":
            return .empty
        case "items":
            return .items(summaries(from: payload.rows))
        default:
            return .unsupportedPage
        }
    }

    static func summaries(from rows: [Row]) -> [MergeRequestSummary] {
        var seenURLStrings = Set<String>()
        var results: [MergeRequestSummary] = []

        for row in rows {
            guard let url = normalizedMRURL(from: row.url),
                  let title = displayTitle(for: row)
            else { continue }

            let urlString = url.absoluteString
            guard !seenURLStrings.contains(urlString) else { continue }
            seenURLStrings.insert(urlString)

            let draftFromTitle = Self.isDraftTitle(title)

            results.append(
                MergeRequestSummary(
                    id: url,
                    iidText: row.iid.flatMap(nonEmpty),
                    title: draftFromTitle.stripped,
                    projectDisplayName: row.project.flatMap(nonEmpty),
                    authorDisplayName: row.author.flatMap(nonEmpty),
                    isDraft: row.isDraft || draftFromTitle.isDraft,
                    pipelineDisplayState: row.pipeline.flatMap(nonEmpty),
                    reviewDisplayState: row.review.flatMap(nonEmpty),
                    updatedText: row.updated.flatMap(nonEmpty),
                    targetVersionText: row.target.flatMap(nonEmpty),
                    mergeRequestURL: url,
                    sourceOrder: results.count
                )
            )
        }

        return results
    }

    /// Normalizes to an absolute http(s) URL without its fragment.
    static func normalizedMRURL(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        guard let cleaned = components?.url else { return nil }
        return cleaned
    }

    private nonisolated static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func displayTitle(for row: Row) -> String? {
        guard let raw = row.title else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Detects `Draft:` / `WIP:` / `[Draft]` / `[WIP]` title prefixes and
    /// returns the title with that prefix stripped so the card's Draft cue is
    /// not repeated inside the title.
    private static func isDraftTitle(_ title: String) -> (isDraft: Bool, stripped: String) {
        let pattern = #"^\s*(\[(?:draft|wip)\]\s*|(?:draft|wip)\s*[:：]\s*)"#
        guard let range = title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return (false, title)
        }
        let stripped = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (true, stripped.isEmpty ? title : stripped)
    }
}
