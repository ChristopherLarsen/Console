import Foundation

// MARK: - Raw App Data

struct RawAppData: Codable {
    let bundleURL: String
    var bundleID: String?
    var displayName: String?
    var version: String?
    var hasAppleScriptDictionary: Bool = false
    var applescriptDictionaryXML: String?
    var parsedDictionary: ParsedScriptDictionary?
    var hasAppIntentsMetadata: Bool = false
    var appIntentsMetadataKeys: [String] = []
    var shortcutsActions: [ShortcutAction] = []
}

struct ShortcutAction: Codable {
    let identifier: String
    let title: String
    let description: String?
    let parameterSummary: String?
    let category: String?
}

// MARK: - Discovery Summary

struct DiscoverySummary: Codable {
    let discoveredAt: String
    let totalApps: Int
    let appsWithAppleScript: Int
    let appsWithAppIntents: Int
    let apps: [RawAppData]
}

// MARK: - Catalog Discoverer

class CatalogDiscoverer {
    private let fileManager = FileManager.default
    private let verbose: Bool

    init(verbose: Bool = false) {
        self.verbose = verbose
    }

    func discoverApp(_ appURL: URL) -> RawAppData {
        var data = RawAppData(bundleURL: appURL.path)

        if let bundle = Bundle(url: appURL) {
            data.bundleID = bundle.bundleIdentifier
            data.displayName = bundle.infoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.infoDictionary?["CFBundleName"] as? String
                ?? appURL.deletingPathExtension().lastPathComponent
            data.version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? bundle.infoDictionary?["CFBundleVersion"] as? String
        }

        let sdefXML = extractScriptDictionary(appURL)
        data.hasAppleScriptDictionary = sdefXML != nil
        data.applescriptDictionaryXML = sdefXML

        if let xml = sdefXML {
            let parser = AppleScriptDictionaryParser()
            data.parsedDictionary = parser.parse(xml)
        }

        let intentsMetadata = extractAppIntentsMetadata(appURL)
        data.hasAppIntentsMetadata = intentsMetadata != nil
        if let metadata = intentsMetadata {
            data.appIntentsMetadataKeys = Array(metadata.keys)
        }

        if let bundleID = data.bundleID {
            data.shortcutsActions = queryShortcutsDatabase(bundleID)
        }

        if verbose {
            let name = data.displayName ?? "Unknown"
            let sdef = data.hasAppleScriptDictionary ? "✓" : "✗"
            let intents = data.hasAppIntentsMetadata ? "✓" : "✗"
            var detail = "sdef:\(sdef) intents:\(intents)"
            if let parsed = data.parsedDictionary {
                detail += " cmds:\(parsed.allCommands.count) classes:\(parsed.allClasses.count)"
            }
            print("  \(name) (\(data.bundleID ?? "?")) — \(detail)")
        }

        return data
    }

    func discoverAllApps(at paths: [String] = ["/Applications"]) -> [RawAppData] {
        var discoveredApps: [RawAppData] = []

        for basePath in paths {
            let baseURL = URL(fileURLWithPath: basePath)
            guard let enumerator = fileManager.enumerator(
                at: baseURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                if verbose { print("  Could not enumerate: \(basePath)") }
                continue
            }

            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "app" {
                    // Don't descend into .app bundles
                    enumerator.skipDescendants()

                    let appData = discoverApp(fileURL)
                    if appData.bundleID != nil {
                        discoveredApps.append(appData)
                    }
                }
            }
        }

        return discoveredApps.sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
    }

    func buildSummary(from apps: [RawAppData]) -> DiscoverySummary {
        let formatter = ISO8601DateFormatter()
        return DiscoverySummary(
            discoveredAt: formatter.string(from: Date()),
            totalApps: apps.count,
            appsWithAppleScript: apps.filter(\.hasAppleScriptDictionary).count,
            appsWithAppIntents: apps.filter(\.hasAppIntentsMetadata).count,
            apps: apps
        )
    }

    func writeSummary(_ summary: DiscoverySummary, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        try data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - AppleScript Dictionary Extraction

    private func extractScriptDictionary(_ appURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sdef")
        process.arguments = [appURL.path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // Timeout after 5 seconds to avoid hangs on problematic apps
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            if verbose { print("    sdef timed out for \(appURL.lastPathComponent)") }
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let xml = String(data: data, encoding: .utf8), !xml.isEmpty else {
            return nil
        }
        return xml
    }

    // MARK: - App Intents Metadata Extraction

    private func extractAppIntentsMetadata(_ appURL: URL) -> [String: Any]? {
        let metadataPath = appURL
            .appendingPathComponent("Contents/Resources/AppIntents.metadata.plist")

        guard fileManager.fileExists(atPath: metadataPath.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: metadataPath)
            let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            )
            return plist as? [String: Any]
        } catch {
            if verbose { print("  Error reading AppIntents metadata: \(error)") }
            return nil
        }
    }

    // MARK: - Shortcuts Database (Experimental)

    private func queryShortcutsDatabase(_ bundleID: String) -> [ShortcutAction] {
        // Experimental: the Shortcuts DB location and schema are not stable
        // Stubbed for future implementation
        return []
    }
}
