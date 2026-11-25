import Foundation

struct OrchestratorPlan: Codable, Equatable {
    struct Step: Codable, Equatable {
        enum Status: String, Codable {
            case pending, held, running, blocked, failed, completed, cancelled
        }

        var id: String
        var ownerSession: UUID?
        var ownerConversation: UUID?
        var directive: String
        var status: Status

        enum CodingKeys: String, CodingKey {
            case id, directive, status
            case ownerSession = "owner_session"
            case ownerConversation = "owner_conversation"
        }
    }

    struct Decision: Codable, Equatable {
        var id: Int
        var question: String
        var options: [String]
        var answer: String?
        var presented: Bool?
        /// Console ID of the session the decision is about. Kept as text so a
        /// malformed value cannot make the whole plan unreadable.
        var session: String?
        /// Fallback card title when no live session matches.
        var title: String?
        /// Short current state the user needs in order to decide.
        var summary: String?
        /// The option the Orchestrator recommends; shown first on the card.
        var recommended: String?

        /// Options in card order: the recommendation first, the rest as given.
        var orderedOptions: [String] {
            guard let recommended, options.contains(recommended) else { return options }
            return [recommended] + options.filter { $0 != recommended }
        }
    }

    var revision = 0
    var goal = ""
    var steps: [Step] = []
    var decisions: [Decision] = []

    var isValid: Bool {
        revision >= 0 && revision < Int.max
            && Set(steps.map(\.id)).count == steps.count
            && steps.allSatisfy { !$0.id.isEmpty && !$0.directive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && Set(decisions.map(\.id)).count == decisions.count
            && decisions.allSatisfy { decision in
                decision.id > 0 && !decision.question.isEmpty && !decision.options.isEmpty
                    && (decision.answer.map { decision.options.contains($0) } ?? true)
            }
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

extension OrchestratorPlan {
    /// Only `revision` is required; everything else defaults, so the
    /// Orchestrator can save a plan with decisions and no steps.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            revision: try container.decode(Int.self, forKey: .revision),
            goal: try container.decodeIfPresent(String.self, forKey: .goal) ?? "",
            steps: try container.decodeIfPresent([Step].self, forKey: .steps) ?? [],
            decisions: try container.decodeIfPresent([Decision].self, forKey: .decisions) ?? []
        )
    }
}
