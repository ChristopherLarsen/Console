import Foundation
import SwiftData

@MainActor
final class AppDependencies {
    static let shared = AppDependencies()

    var menuBarViewModel: MenuBarViewModel?
    var modelContainer: ModelContainer?
    var aiProviderManager: AIProviderManager?
    var localCommandExecutor: LocalCommandExecutor?

    private init() {}
}
