import SwiftUI

/// A single screen for requesting permissions and showing their current OS state.
struct PermissionsView: View {
    @Environment(PermissionBackgroundObserver.self) private var permissionObserver: PermissionBackgroundObserver?
    @State private var fallbackViewModel = PermissionsViewModel()
    @State private var requestingPermission: PermissionType?

    var onDismiss: (() -> Void)? = nil

    private var viewModel: PermissionsViewModel {
        permissionObserver?.viewModel ?? fallbackViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Permissions")
                    .font(.title2.bold())
                Spacer()
                if let onDismiss {
                    CloseButton(action: onDismiss)
                }
            }
            .padding(20)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(viewModel.permissionStates) { state in
                        permissionRow(state)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Keep the visible rows current even while System Settings is active.
            // SwiftUI cancels this loop when the permissions screen disappears.
            while !Task.isCancelled {
                await viewModel.refreshAllStatuses()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await viewModel.refreshAllStatuses() }
        }
    }

    private func permissionRow(_ state: PermissionState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: state.info.icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)

            Text(state.info.name)
                .fontWeight(.medium)

            Spacer()

            Label(state.currentStatus.displayLabel, systemImage: state.currentStatus.indicatorIcon)
                .font(.caption)
                .foregroundStyle(state.currentStatus.indicatorColor)

            Button(actionLabel(for: state)) {
                requestingPermission = state.type
                Task {
                    defer { requestingPermission = nil }
                    await viewModel.requestPermission(state.type)
                }
            }
            .buttonStyle(.bordered)
            .disabled(requestingPermission != nil || state.currentStatus == .granted || state.currentStatus == .restricted)
            .accessibilityLabel("\(actionLabel(for: state)) — \(state.info.name)")
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func actionLabel(for state: PermissionState) -> String {
        if requestingPermission == state.type {
            return "Requesting…"
        }
        switch state.currentStatus {
        case .granted: return "Granted"
        case .restricted: return "Restricted"
        case .denied: return "Open System Settings"
        default: return "Grant Permission"
        }
    }
}

#Preview {
    PermissionsView()
        .frame(width: 600, height: 400)
}
