import SwiftUI
import SwiftData

enum CommandSortOption: String, CaseIterable {
    case alphabetical = "Alphabetical"
    case recent = "Recent"
    case console = "Console"
    case myCommands = "My Commands"
}

struct CommandListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Command.name) private var commands: [Command]

    @Environment(AIProviderManager.self) private var aiProviderManager

    @State private var showCreationSheet = false
    @State private var showNoProviderAlert = false
    @State private var commandToDelete: Command?
    @State private var showDeleteAlert = false
    @State private var selectedCommand: Command?
    
    @State private var expandedCommandIDs: Set<UUID> = []
    @State private var sortOption: CommandSortOption = .alphabetical
    @State private var availableHeight: CGFloat = 600

    private var sortedCommandList: [Command] {
        switch sortOption {
        case .alphabetical:
            return commands.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recent:
            return commands.sorted { a, b in
                let dateA = a.lastExecutedAt ?? .distantPast
                let dateB = b.lastExecutedAt ?? .distantPast
                return dateA > dateB
            }
        case .console:
            return commands.filter(\.isConsole)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .myCommands:
            return commands.filter { !$0.isConsole }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if commands.isEmpty {
                emptyState
            } else {
                commandList
            }
        }
        
        .background(GeometryReader { geo in
            Color.clear.onAppear { availableHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, newHeight in availableHeight = newHeight }
        })
        .sheet(isPresented: $showCreationSheet) {
            CommandCreationView(maxHeight: availableHeight - 100)
        }
        .sheet(item: $selectedCommand) { command in
            CommandDetailView(command: command)
        }
        .alert("Delete Command?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { commandToDelete = nil }
            Button("Delete", role: .destructive) { confirmDelete() }
        } message: {
            if let cmd = commandToDelete {
                Text("Permanently delete \"\(cmd.name)\"?")
            }
        }
        .overlay {
            if showNoProviderAlert {
                noProviderOverlay
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCommandCreation)) { _ in
            if showCreationSheet {
                showCreationSheet = false
            } else {
                handleAddCommand()
            }
        }
    
    }

    // MARK: - No Provider Alert

    private var noProviderOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showNoProviderAlert = false
                    }
                }

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)

                Text("No AI Provider Selected")
                    .font(.headline)

                Text("Would you like to go to AI Provider to set one up for Console?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)

                HStack(spacing: 12) {
                    CapsuleButton("Cancel", style: .neutral) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showNoProviderAlert = false
                        }
                    }

                    CapsuleButton("OK", style: .primary) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showNoProviderAlert = false
                        }
                        ConsoleNavigation.showAIProvider()
                    }
                }
                .padding(.top, 4)
            }
            .padding(28)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        }
        .transition(.opacity)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Commands")
                    .font(.headline)
                if commands.count > 0 {
                    Text("\(commands.count) command\(commands.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            Menu {
                ForEach(CommandSortOption.allCases, id: \.self) { option in
                    Button {
                        sortOption = option
                    } label: {
                        HStack {
                            Text(option.rawValue)
                            if sortOption == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .accessibilityIdentifier(option.rawValue)
                }
            } label: {
                Text(sortOption.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(sortOption.rawValue)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort and filter commands")

            Divider()
                .frame(height: 20)

            Button {
                handleAddCommand()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 25))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("New Command")
        }
        .padding(16)
    }

    // MARK: - Command List

    private var commandList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(sortedCommandList) { command in
                    ExpandableCommandRow(
                        command: command,
                        isExpanded: expandedCommandIDs.contains(command.id),
                        onToggleExpand: { toggleExpanded(command.id) },
                        onDelete: {
                            commandToDelete = command
                            showDeleteAlert = true
                        },
                        onTest: { await testCommand(command) },
                        onEdit: { selectedCommand = command },
                        onSave: { persistChanges() }
                    )
                    .id(command.id)
                    .onTapGesture {
                        withAnimation { toggleExpanded(command.id) }
                    }
                    .contextMenu {
                        commandContextMenu(for: command)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func commandContextMenu(for command: Command) -> some View {
        if !command.isConsole {
            Button {
                duplicateCommand(command)
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
        }

        Button {
            _ = CommandExporter.copyToClipboard([command])
        } label: {
            Label("Copy as JSON", systemImage: "square.and.arrow.up")
        }

        if !command.isProtected {
            Divider()

            Button(role: .destructive) {
                commandToDelete = command
                showDeleteAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image("yellow_buddy")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)

            Text("No Commands Yet!")
                .font(.title3.weight(.medium))

            Text("Use your AI provider to\n**create a command**")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                handleAddCommand()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 25))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - Actions

    private func toggleExpanded(_ id: UUID) {
        if expandedCommandIDs.contains(id) {
            expandedCommandIDs.remove(id)
        } else {
            expandedCommandIDs.insert(id)
        }
    }

    private func testCommand(_ command: Command) async {
        let executor = LocalCommandExecutor()
        executor.modelContext = modelContext
        _ = await executor.execute(command)
    }

    private func confirmDelete() {
        guard let command = commandToDelete else { return }
        modelContext.delete(command)
        persistChanges()
        commandToDelete = nil
    }

    private func duplicateCommand(_ command: Command) {
        let copy = Command(
            name: "\(command.name) Copy",
            commandDescription: command.commandDescription,
            triggerPhrases: command.triggerPhrases,
            actions: command.actions.map {
                CommandAction(type: $0.type, payload: $0.payload, order: $0.order,
                              delayAfterMS: $0.delayAfterMS, timeoutMS: $0.timeoutMS,
                              retryOnFailure: $0.retryOnFailure, maxRetries: $0.maxRetries)
            },
            executionMode: command.executionMode,
            requiresConfirmation: command.requiresConfirmation,
            shortSummary: command.shortSummary,
            actionDescription: command.actionDescription
        )
        modelContext.insert(copy)
        persistChanges()
    }

    private func handleAddCommand() {
        if aiProviderManager.selectedProvider == .none {
            showNoProviderAlert = true
        } else {
            showCreationSheet = true
        }
    }

    private func persistChanges() {
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .commandVocabularyDidChange, object: nil)
        } catch {
            printDebug("[Console] Failed to persist command changes: \(error)")
        }
    }

}
