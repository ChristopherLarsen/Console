import Foundation

/// User-selected iOS execution settings for one `SessionWorkspace`.
/// Persists only local configuration: project path, scheme, configuration,
/// optional test plan, and Simulator UDID. Signing credentials and source
/// content are never stored.
nonisolated struct IOSProjectProfile: Codable, Equatable, Sendable {
    var workspaceID: UUID
    var projectPath: String?
    var scheme: String?
    var configuration: String?
    var testPlan: String?
    var simulatorUDID: String?

    static func empty(workspaceID: UUID) -> IOSProjectProfile {
        IOSProjectProfile(workspaceID: workspaceID)
    }

    init(
        workspaceID: UUID,
        projectPath: String? = nil,
        scheme: String? = nil,
        configuration: String? = nil,
        testPlan: String? = nil,
        simulatorUDID: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.projectPath = Self.nilIfEmpty(projectPath)
        self.scheme = Self.nilIfEmpty(scheme)
        self.configuration = Self.nilIfEmpty(configuration)
        self.testPlan = Self.nilIfEmpty(testPlan)
        self.simulatorUDID = Self.nilIfEmpty(simulatorUDID)
    }

    func normalized() -> IOSProjectProfile {
        IOSProjectProfile(
            workspaceID: workspaceID,
            projectPath: projectPath,
            scheme: scheme,
            configuration: configuration,
            testPlan: testPlan,
            simulatorUDID: simulatorUDID
        )
    }

    static func nilIfEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum IOSProjectKind: String, Codable, Sendable, Equatable {
    case workspace
    case project
}

nonisolated struct IOSProjectCandidate: Equatable, Sendable, Identifiable {
    var id: String { path }
    var path: String
    var kind: IOSProjectKind

    var displayName: String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    var parentDirectoryPath: String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    var filename: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    init?(path: String) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardized.hasSuffix(".xcworkspace") {
            kind = .workspace
        } else if standardized.hasSuffix(".xcodeproj") {
            kind = .project
        } else {
            return nil
        }
        self.path = standardized
    }
}

nonisolated struct IOSProjectListing: Equatable, Sendable {
    var name: String
    var schemes: [String]
    var configurations: [String]
    var targets: [String]
    /// `nil` means test plans were not fetched or the lookup failed.
    var testPlans: [String]?
}

nonisolated struct IOSSimulatorDestination: Equatable, Sendable, Identifiable {
    var id: String { udid }
    var udid: String
    var name: String
    var osVersion: String?
    var platform: String

    var displayName: String {
        if let osVersion, !osVersion.isEmpty {
            return "\(name) · \(osVersion)"
        }
        return name
    }
}

nonisolated enum IOSLookup<Value: Equatable>: Equatable {
    case succeeded(Value)
    case failed
    case skipped
}

nonisolated enum IOSDiscoveryPhase: Equatable, Sendable {
    case listingSchemes
    case listingTestPlans
    case listingDestinations
}

nonisolated struct IOSDiscoveryRefreshResult: Equatable, Sendable {
    var listing: IOSProjectListing?
    var destinations: [IOSSimulatorDestination]
    var repair: IOSProfileRepair.Outcome
    var errorMessage: String?
    /// Raw lookup statuses so consumers can tell "confirmed unavailable"
    /// apart from "the lookup itself failed or was skipped".
    var listingLookup: IOSLookup<IOSProjectListing> = .skipped
    var destinationLookup: IOSLookup<[IOSSimulatorDestination]> = .skipped
}

nonisolated enum IOSProfileRepair {
    enum Issue: Equatable, Sendable {
        case projectNotSelected
        case savedProjectMissing(String)
        case savedSchemeMissing(String)
        case savedConfigurationMissing(String)
        case savedTestPlanMissing(String)
        case savedSimulatorMissing(String)

        var message: String {
            switch self {
            case .projectNotSelected:
                return "No Xcode project selected. Choose one for this workspace."
            case .savedProjectMissing(let path):
                let name = URL(fileURLWithPath: path).lastPathComponent
                return "Saved project “\(name)” is missing. Choose another project."
            case .savedSchemeMissing(let name):
                return "Saved scheme “\(name)” is not in this project. Choose a current scheme."
            case .savedConfigurationMissing(let name):
                return "Saved configuration “\(name)” is not in this project. Choose a current configuration."
            case .savedTestPlanMissing(let name):
                return "Saved test plan “\(name)” is not in this scheme. Choose another plan or None."
            case .savedSimulatorMissing(let udid):
                return "Saved Simulator \(udid) is not available. Choose a current Simulator."
            }
        }
    }

    struct Outcome: Equatable, Sendable {
        var profile: IOSProjectProfile
        var issues: [Issue]
        var didChangeProfile: Bool
    }

    /// Merges discovery into a saved profile without clearing valid fields.
    /// Auto-fills only empty fields when the choice is unambiguous. Failed
    /// lookups never treat missing lists as a reason to wipe saved values.
    /// The project itself is never chosen automatically — the user selects it.
    static func resolve(
        saved: IOSProjectProfile,
        listing: IOSLookup<IOSProjectListing>,
        destinations: IOSLookup<[IOSSimulatorDestination]>,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Outcome {
        let original = saved.normalized()
        var profile = original
        var issues: [Issue] = []

        if let path = profile.projectPath {
            if !fileExists(path) {
                issues.append(.savedProjectMissing(path))
            }
        } else {
            issues.append(.projectNotSelected)
        }

        switch listing {
        case .failed, .skipped:
            break
        case .succeeded(let listed):
            if let scheme = profile.scheme {
                if !listed.schemes.contains(scheme) {
                    issues.append(.savedSchemeMissing(scheme))
                }
            } else if listed.schemes.count == 1 {
                profile.scheme = listed.schemes[0]
            }

            if let configuration = profile.configuration {
                if !listed.configurations.isEmpty && !listed.configurations.contains(configuration) {
                    issues.append(.savedConfigurationMissing(configuration))
                }
            } else if listed.configurations.count == 1 {
                profile.configuration = listed.configurations[0]
            }

            if let testPlans = listed.testPlans, let plan = profile.testPlan, !testPlans.contains(plan) {
                issues.append(.savedTestPlanMissing(plan))
            }
        }

        switch destinations {
        case .failed, .skipped:
            break
        case .succeeded(let devices):
            if let udid = profile.simulatorUDID {
                if !devices.contains(where: { $0.udid == udid }) {
                    issues.append(.savedSimulatorMissing(udid))
                }
            } else if devices.count == 1 {
                profile.simulatorUDID = devices[0].udid
            }
        }

        profile = profile.normalized()
        return Outcome(
            profile: profile,
            issues: issues,
            didChangeProfile: profile != original
        )
    }
}
