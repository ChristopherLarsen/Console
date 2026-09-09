import SwiftUI
import SwiftData

/// Segmented section shown inside the consolidated Commands hub.
enum CommandsHubTab: String, CaseIterable, Identifiable {
    case triggers
    case commands

    var id: String { rawValue }

    var label: String {
        switch self {
        case .triggers: return "Triggers"
        case .commands: return "Commands"
        }
    }
}

/// Consolidated Triggers + Commands destination, opened by the sidebar
/// Commands item. A segmented control at the top picks which section renders.
struct CommandsHubView: View {
    @AppStorage(ConsoleNavigation.commandsHubTabKey) private var hubTab: CommandsHubTab = .commands

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $hubTab) {
                ForEach(CommandsHubTab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityIdentifier("CommandsHubSegmented")

            switch hubTab {
            case .triggers:
                TriggersView()
            case .commands:
                CommandListView()
            }
        }
    }
}

#Preview {
    CommandsHubView()
        .environment(AIProviderManager())
        .environment(LocalCommandExecutor())
        .modelContainer(for: [Command.self, WakeWord.self], inMemory: true)
}
