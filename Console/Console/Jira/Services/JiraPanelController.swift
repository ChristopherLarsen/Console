import Foundation

enum JiraPanelState: Equatable {
    case unconfigured
    case loadingPage
    case authenticationRequired
    case extracting
    case loaded(tickets: [JiraTicketSummary], refreshedAt: Date)
    case empty(refreshedAt: Date)
    case stale(tickets: [JiraTicketSummary], refreshedAt: Date, reason: String)
    case unsupportedPage
    case extractionFailed

    var tickets: [JiraTicketSummary] {
        switch self {
        case let .loaded(tickets, _), let .stale(tickets, _, _):
            return tickets
        default:
            return []
        }
    }

    var refreshedAt: Date? {
        switch self {
        case let .loaded(_, date), let .empty(date), let .stale(_, date, _):
            return date
        default:
            return nil
        }
    }

    var hasCards: Bool {
        !tickets.isEmpty
    }
}

@MainActor
@Observable
final class JiraPanelController {
    private(set) var state: JiraPanelState = .unconfigured
    private(set) var showsBrowser = false
    private(set) var isRefreshing = false

    private var generation = 0
    private var configuredURLString: String?
    private nonisolated(unsafe) let injectedService: (any JiraPageServicing)?
    private var service: any JiraPageServicing {
        if let injectedService {
            return injectedService
        }
        return JiraWebSession.shared
    }

    nonisolated init(service: (any JiraPageServicing)? = nil) {
        self.injectedService = service
    }

    func configure(url: URL?) {
        let urlString = url?.absoluteString
        let sameURL = urlString == configuredURLString

        guard let url else {
            generation += 1
            configuredURLString = urlString
            state = .unconfigured
            showsBrowser = false
            return
        }

        if sameURL, state.hasCards || isPositiveEmptyState {
            return
        }

        configuredURLString = urlString
        generation += 1
        state = .loadingPage
        showsBrowser = false
        Task {
            await startExtraction(url: url, generation: generation)
        }
    }

    func refresh() {
        guard let urlString = configuredURLString, let url = URL(string: urlString) else { return }
        generation += 1
        isRefreshing = true
        if !state.hasCards {
            state = .loadingPage
        }
        Task {
            await startExtraction(url: url, generation: generation, reloadFirst: true)
        }
    }

    func showJIRA() {
        showsBrowser = true
    }

    func showCards() {
        guard state.hasCards || isPositiveEmptyState else { return }
        showsBrowser = false
    }

    func open(_ ticket: JiraTicketSummary) {
        openIssue(at: ticket.issueURL)
    }

    /// Reveals the retained page and navigates it to a captured issue URL.
    func openIssue(at url: URL) {
        showsBrowser = true
        service.navigate(to: url)
    }

    private var isPositiveEmptyState: Bool {
        if case .empty = state { return true }
        return false
    }

    private func startExtraction(url: URL, generation startGeneration: Int, reloadFirst: Bool = false) async {
        if reloadFirst {
            service.reload()
        } else if service.lastLoadedURLString != url.absoluteString || service.pageURL == nil {
            service.load(url: url)
        }

        let readiness = await waitForListOrAuthentication(generation: startGeneration)
        guard startGeneration == generation else { return }

        if readiness == .authenticationDetected {
            enterAuthenticationRequired(generation: startGeneration)
            return
        }

        await finishExtraction(generation: startGeneration)
    }

    private func finishExtraction(generation startGeneration: Int) async {
        if !state.hasCards {
            state = .extracting
        }
        let extraction = await service.extractTickets()
        guard startGeneration == generation else { return }
        isRefreshing = false

        apply(extraction: extraction)

        if case .authenticationRequired = state {
            watchForPostAuthentication(generation: startGeneration)
        }
    }

    private func enterAuthenticationRequired(generation startGeneration: Int) {
        state = .authenticationRequired
        showsBrowser = true
        isRefreshing = false
        watchForPostAuthentication(generation: startGeneration)
    }

    private func watchForPostAuthentication(generation startGeneration: Int) {
        Task {
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                guard startGeneration == generation else { return }
                guard case .authenticationRequired = state else { return }
                let snapshot = await service.readiness()
                guard startGeneration == generation else { return }
                var listIsBack = false
                if case let .pending(hasRows, hasContainer) = snapshot {
                    // A container without rows can be a legitimate signed-in
                    // empty list; it must recover too, not wait on rows that
                    // will never come. The bounded readiness pipeline that
                    // follows decides empty versus rows.
                    listIsBack = hasRows || hasContainer
                }
                if listIsBack, startGeneration == generation, let url = configuredURL() {
                    await startExtraction(url: url, generation: startGeneration)
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func configuredURL() -> URL? {
        configuredURLString.flatMap(URL.init(string:))
    }

    private func apply(extraction: JiraListExtraction) {
        switch extraction {
        case let .tickets(tickets):
            state = .loaded(tickets: tickets, refreshedAt: Date())
            showsBrowser = false
        case .empty:
            state = .empty(refreshedAt: Date())
            showsBrowser = false
        case .authenticationRequired:
            state = .authenticationRequired
            showsBrowser = true
        case .unsupportedPage:
            if state.hasCards {
                state = makeStale(reason: "list unavailable")
            } else {
                state = .unsupportedPage
                showsBrowser = true
            }
        case .failed:
            if state.hasCards {
                state = makeStale(reason: "could not read list")
            } else {
                state = .extractionFailed
                showsBrowser = true
            }
        }
    }

    private func makeStale(reason: String) -> JiraPanelState {
        if case let .loaded(tickets, refreshedAt) = state {
            return .stale(tickets: tickets, refreshedAt: refreshedAt, reason: reason)
        }
        return state
    }

    private func waitForListOrAuthentication(generation startGeneration: Int) async -> ReadinessOutcome {
        let deadline = Date().addingTimeInterval(15)
        var sawListContainer = false
        while Date() < deadline {
            guard startGeneration == generation else { return .cancelled }
            let snapshot = await service.readiness()
            guard startGeneration == generation else { return .cancelled }
            switch snapshot {
            case .authenticationDetected:
                return .authenticationDetected
            case let .pending(hasRows, hasContainer):
                if hasRows { return .ready }
                if hasContainer { sawListContainer = true }
            case .none:
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        _ = sawListContainer
        return .timedOut
    }

    enum ReadinessOutcome {
        case ready
        case authenticationDetected
        case timedOut
        case cancelled
    }
}

@MainActor
protocol JiraPageServicing: AnyObject {
    var lastLoadedURLString: String? { get }
    var pageURL: URL? { get }
    func load(url: URL)
    func reload()
    func navigate(to url: URL)
    func readiness() async -> JiraReadiness?
    func extractTickets() async -> JiraListExtraction
}

enum JiraReadiness: Equatable {
    case pending(hasRows: Bool, hasContainer: Bool)
    case authenticationDetected
}
