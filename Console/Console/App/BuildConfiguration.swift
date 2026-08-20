import Foundation

enum BuildConfiguration {

    static var current: String {
        "Direct Download Edition"
    }

    static let appVersion: String? =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    static let buildNumber: String? =
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String

    static var versionDisplay: String? {
        guard let appVersion else { return nil }
        if let buildNumber { return "\(appVersion) (\(buildNumber))" }
        return appVersion
    }
}
