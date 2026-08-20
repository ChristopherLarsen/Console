import SwiftUI

struct AuthorizationDialog: View {
    let command: Command
    let authorizationWords: [String]
    let allowVoiceAuth: Bool
    let initialTimeout: Int
    let onAuthorize: () -> Void
    let onCancel: () -> Void

    @State private var timeRemaining: Int = 15
    @State private var countdownTimer: Timer?

    var body: some View {
        VStack(spacing: 20) {
            headerSection
            summaryCard
            instructionText
            buttonRow
        }
        .padding(24)
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { startTimer() }
        .onDisappear { countdownTimer?.invalidate() }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top) {
            Image("buddy_red")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text("Authorization Required")
                    .font(.headline)

                Text(command.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(timeRemaining)s")
                .font(.title2.monospacedDigit().bold())
                .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This command will:")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(LocalizedStringKey(summaryText))
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var summaryText: String {
        if !command.shortSummary.isEmpty {
            return command.shortSummary
        }
        return command.displayActionDescription
    }

    // MARK: - Instruction

    private var instructionText: some View {
        VStack(spacing: 4) {
            if allowVoiceAuth, let firstWord = authorizationWords.first {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Say \"\(firstWord)\" to authorize")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Buttons

    private var buttonRow: some View {
        HStack(spacing: 16) {
            CapsuleButton("Cancel", style: .neutral) {
                countdownTimer?.invalidate()
                onCancel()
            }

            CapsuleButton("Authorized", systemImage: "checkmark.shield", style: .primary) {
                countdownTimer?.invalidate()
                onAuthorize()
            }
        }
    }

    // MARK: - Timer

    private func startTimer() {
        timeRemaining = initialTimeout
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                if timeRemaining > 0 {
                    timeRemaining -= 1
                } else {
                    countdownTimer?.invalidate()
                    onCancel()
                }
            }
        }
    }
}
