import AppKit
import SwiftUI

struct NotePanelView: View {
    let viewModel: NoteViewModel
    @AppStorage("noteFormattingEnabled") private var noteFormattingEnabled: Bool = false
    private let noteYellow = Color(red: 1.0, green: 0.97, blue: 0.94)

    var body: some View {
        VStack(spacing: 12) {
            headerBar
            textArea
            if let error = viewModel.formatError {
                errorBanner(error)
            }
        }
        .padding()
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
        .background(
            noteYellow,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.none, value: viewModel.noteText)
        .animation(.none, value: viewModel.volatileText)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Say")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button { viewModel.clearNote() } label: {
                Text("clear")
                    .font(.caption)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Button { viewModel.undo() } label: {
                Text("undo")
                    .font(.caption)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Button { viewModel.copyToClipboard() } label: {
                Text("copy")
                    .font(.caption)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Button { viewModel.done() } label: {
                Text("done")
                    .font(.caption)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            if viewModel.showCopiedFeedback {
                Text("Copied")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()
        }
        .padding(.leading, 8)
    }

    // MARK: - Text Area

    private var textArea: some View {
        NoteTextView(
            noteText: Binding(
                get: { viewModel.noteText },
                set: { viewModel.noteText = $0 }
            ),
            volatileText: viewModel.volatileText,
            fishIsActive: viewModel.fishIsActive
        )
        .overlay(alignment: .bottomTrailing) {
            if viewModel.showPauseIndicator {
                Circle()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .padding(8)
            }
        }
        .overlay {
            if viewModel.isFormatting {
                ZStack {
                    Color.black.opacity(0.3)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    ProgressView("Formatting...")
                        .foregroundStyle(.white)
                }
            }
        }
        .animation(.none, value: viewModel.showPauseIndicator)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            Button {
                viewModel.formatError = nil
            } label: {
                Label("Dismiss", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
