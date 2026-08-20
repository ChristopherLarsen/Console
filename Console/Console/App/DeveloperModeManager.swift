import Foundation
import Observation

#if DEBUG
/// Controls developer feature visibility independently from the DEBUG build flag.
/// Allows previewing the production experience while running in Xcode.
@Observable
@MainActor
final class DeveloperModeManager {
    static let shared = DeveloperModeManager()

    private static let userDefaultsKey = "com.console.developerModeEnabled"

    var isDeveloperModeEnabled: Bool {
        didSet { UserDefaults.standard.set(isDeveloperModeEnabled, forKey: Self.userDefaultsKey); UserDefaults.standard.synchronize() }
    }

    init() {
        self.isDeveloperModeEnabled = UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
    }

    func toggleDeveloperMode() {
        isDeveloperModeEnabled.toggle()
    }
}
#endif
