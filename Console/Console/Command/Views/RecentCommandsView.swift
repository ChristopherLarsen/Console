import SwiftUI
import Combine

struct RecentCommandsView: View {
    let commands: [Command]
    let triggerWord: String
    let onDismiss: () -> Void
    let onExecute: (Command) -> Void

    @State private var progress: CGFloat = 1.0
    @State private var isPaused = false
    @State private var startDate = Date()
    @State private var hoveredCommandID: UUID?
    @State private var isViewHovered = false

    private let autoDismissDuration: Double = 20.0
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private var sortedCommands: [Command] {
        commands
            .filter { $0.isEnabled && !($0.isConsole && $0.actions.first?.payload == ConsoleAction.showRecentCommands.rawValue) }
            .sorted { a, b in
                switch (a.lastExecutedAt, b.lastExecutedAt) {
                case let (aDate?, bDate?):
                    return aDate > bDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)

            countdownBar
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(sortedCommands) { command in
                        commandRow(command)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, _ in
                pauseCountdown()
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 400)
        .background(Color(red: 0.35, green: 0.15, blue: 0.0).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isViewHovered = hovering
            }
            if hovering {
                pauseCountdown()
            }
        }
        .onAppear {
            startDate = Date()
        }
        .onReceive(timer) { now in
            guard !isPaused else { return }
            let elapsed = now.timeIntervalSince(startDate)
            progress = max(0, 1.0 - elapsed / autoDismissDuration)
            if progress <= 0 {
                isPaused = true
                onDismiss()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Say \"\(triggerWord)\" +")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Spacer()

            CloseButton(tint: .white) { onDismiss() }
                .opacity(isViewHovered ? 1 : 0)
        }
    }

    // MARK: - Countdown Bar

    private var countdownBar: some View {
        GeometryReader { geo in
            let barWidth = geo.size.width * progress

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.white.opacity(0.08))

                // Active fill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.55, blue: 0.1),
                                Color(red: 1.0, green: 0.35, blue: 0.05)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, barWidth))
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 4, y: 0)
            }
        }
        .frame(height: 3)
        .opacity(isPaused ? 0 : 1)
        .animation(.easeOut(duration: 0.4), value: isPaused)
    }

    // MARK: - Command Row

    private func commandRow(_ command: Command) -> some View {
        let phrase = command.triggerPhrases.first ?? command.name
        let isHovered = hoveredCommandID == command.id

        return Button {
            onExecute(command)
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    if isHovered {
                        Image(systemName: "fish.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .transition(.opacity)
                    }
                }
                .frame(width: 15)

                Text("\"\(phrase)\"")
                    .font(.callout)
                    .foregroundStyle(command.isConsole ? Color.accentColor : .white)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(isHovered ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                hoveredCommandID = hovering ? command.id : nil
            }
        }
    }

    // MARK: - Timer Control

    private func pauseCountdown() {
        guard !isPaused else { return }
        // Grace period: ignore hover events during the first second after the
        // panel appears, because the panel opens directly under the cursor and
        // SwiftUI fires onHover(true) immediately — which would kill the bar.
        guard Date().timeIntervalSince(startDate) > 1.0 else { return }
        isPaused = true
    }
}
