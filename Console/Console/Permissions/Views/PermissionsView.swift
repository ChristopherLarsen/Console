import SwiftUI
import AppKit

/// Permissions overview screen for managing app permissions.
/// Displays all permission categories with their current status.
struct PermissionsView: View {
    @Environment(PermissionBackgroundObserver.self) private var permissionObserver: PermissionBackgroundObserver?
    @State private var fallbackViewModel: PermissionsViewModel?

    @AppStorage("hasSeenPermissionsWelcome") private var hasSeenWelcome = false
    @State private var selectedPermissionForModal: PermissionType?
    @State private var modalStage: PermissionModalStage = .grant

    private enum PermissionModalStage {
        case grant
        case waiting
        case success
        case failure
    }
    
    /// Optional dismiss handler; when set, a close button is shown (modal presentation).
    var onDismiss: (() -> Void)? = nil
    
    /// The viewModel to use (from observer or fallback for previews).
    private var viewModel: PermissionsViewModel {
        permissionObserver?.viewModel ?? fallbackViewModel ?? PermissionsViewModel()
    }
    
    var body: some View {
        ZStack {
            // Main content
            Group {
                if viewModel.allGranted {
                    AllPermissionsGrantedView(viewModel: viewModel)
                } else if !hasSeenWelcome {
                    PermissionsWelcomeView(onGetStarted: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            hasSeenWelcome = true
                        }
                    })
                } else {
                    permissionsListContent
                }
            }
            .allowsHitTesting(selectedPermissionForModal == nil)
            
            // Modal overlay
            if let permissionType = selectedPermissionForModal {
                permissionModalOverlay(for: permissionType)
            }
            
            // Close button for modal presentation
            if let dismiss = onDismiss {
                VStack {
                    HStack {
                        Spacer()
                        CloseButton(action: dismiss)
                            .padding(12)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Initialize fallback for previews if no observer available
            if permissionObserver == nil && fallbackViewModel == nil {
                fallbackViewModel = PermissionsViewModel()
                fallbackViewModel?.onViewAppear()
            }
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.showError },
            set: { viewModel.showError = $0 }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = viewModel.errorMessage {
                Text(message)
            }
        }
    }
    
    // MARK: - Permissions List View
    
    private var permissionsListView: some View {
        Group {
            if viewModel.allGranted {
                AllPermissionsGrantedView(viewModel: viewModel)
            } else {
                permissionsListContent
            }
        }
    }
    
    private var permissionsListContent: some View {
        ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                stickySummaryBadge(scrollProxy: scrollProxy)
                
                ScrollView {
                    VStack(spacing: 16) {
                        header

                        ForEach(viewModel.permissionsByGroup, id: \.group) { group, states in
                            permissionGroupSection(group: group, states: states)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
    }
    
    // MARK: - Sticky Summary Badge
    
    private func stickySummaryBadge(scrollProxy: ScrollViewProxy) -> some View {
        let hasUngranted = viewModel.grantedCount < viewModel.totalCount
        
        return HStack {
            Button {
                scrollToFirstUngranted(scrollProxy: scrollProxy)
            } label: {
                HStack(spacing: 8) {
                    PermissionProgressRing(
                        granted: viewModel.grantedCount,
                        total: viewModel.totalCount,
                        isRefreshing: viewModel.isRefreshing
                    )
                    
                    Text(viewModel.summaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    if hasUngranted {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!hasUngranted)
            .accessibilityHint(hasUngranted ? "Scroll to first ungranted permission" : "")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Header
    
    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            
            Text("Permissions")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Manage what Console can access")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
    
    /// Scroll to the first permission that hasn't been granted.
    private func scrollToFirstUngranted(scrollProxy: ScrollViewProxy) {
        guard let firstUngranted = viewModel.permissionStates.first(where: { $0.currentStatus != .granted }) else {
            return
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            scrollProxy.scrollTo(firstUngranted.type.id, anchor: .center)
        }
    }
    
    // MARK: - Permission Group Section
    
    private func permissionGroupSection(group: PermissionGroup, states: [PermissionState]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Group header
            HStack(spacing: 8) {
                Image(systemName: group.icon)
                    .foregroundStyle(Color.accentColor)
                Text(group.displayName)
                    .font(.headline)
            }
            .padding(.leading, 4)
            
            // Permission rows with IDs for scroll-to support
            VStack(spacing: 8) {
                ForEach(states) { state in
                    PermissionRowView(
                        state: state,
                        viewModel: viewModel,
                        onAction: { permissionType in
                            withAnimation(.easeOut(duration: 0.2)) {
                                modalStage = .grant
                                selectedPermissionForModal = permissionType
                            }
                        }
                    )
                    .id(state.type.id)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Permission Modal Overlay
    
    /// Modal overlay with dimmed background and centered permission grant modal.
    /// Shows grant modal for ungranted permissions, manage modal for granted ones.
    @ViewBuilder
    private func permissionModalOverlay(for permissionType: PermissionType) -> some View {
        // Dimmed background with fade transition
        Color.black.opacity(0.4)
            .ignoresSafeArea()
            .transition(.opacity)
            .onTapGesture {
                // Allow dismissing by tapping outside
                withAnimation(.easeOut(duration: 0.2)) {
                    closeModal()
                }
            }

        let isGranted = viewModel.permissionStatus(for: permissionType) == .granted

        // Modal content with scale + fade transition
        if isGranted {
            PermissionManageModalView(
                permissionType: permissionType,
                onDismiss: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        closeModal()
                    }
                },
                onOpenSettings: {
                    // Open System Settings to the relevant pane
                    if let url = permissionType.systemSettingsURL {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
            .transition(.scale(scale: 0.95).combined(with: .opacity))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        } else {
            Group {
                switch modalStage {
                case .grant:
                    PermissionGrantModalView(
                        permissionType: permissionType,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                closeModal()
                            }
                        },
                        onGrant: { beginGrantFlow(for: permissionType) }
                    )
                case .waiting:
                    PermissionModalWaitingView(
                        permissionType: permissionType,
                        checkPermission: {
                            await viewModel.refreshStatus(for: permissionType)
                            return viewModel.permissionStatus(for: permissionType)
                        },
                        onPermissionGranted: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                modalStage = .success
                            }
                        },
                        onCancel: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                closeModal()
                            }
                        },
                        onOpenSettings: {
                            if let url = permissionType.systemSettingsURL {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    )
                case .success:
                    PermissionModalSuccessView(
                        permissionType: permissionType,
                        onDone: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                closeModal()
                            }
                        }
                    )
                case .failure:
                    PermissionModalFailureView(
                        permissionType: permissionType,
                        onTryAgain: { beginGrantFlow(for: permissionType) },
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                closeModal()
                            }
                        },
                        onOpenSettings: {
                            if let url = permissionType.systemSettingsURL {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    )
                }
            }
            .transition(.scale(scale: 0.95).combined(with: .opacity))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        }
    }

    private func closeModal() {
        selectedPermissionForModal = nil
        modalStage = .grant
    }

    /// Runs the system permission request while the modal shows its waiting
    /// state; the waiting view keeps polling and flips to success, and an
    /// explicit denial lands on the failure view instead of a silent dismiss.
    private func beginGrantFlow(for permissionType: PermissionType) {
        modalStage = .waiting
        Task {
            await viewModel.requestPermission(permissionType)
            let status = viewModel.permissionStatus(for: permissionType)
            withAnimation(.easeOut(duration: 0.2)) {
                if status == .granted {
                    modalStage = .success
                } else if modalStage == .waiting {
                    modalStage = .failure
                }
            }
        }
    }
}

// MARK: - Permission Progress Ring

/// Circular progress ring showing granted/total permission ratio.
private struct PermissionProgressRing: View {
    let granted: Int
    let total: Int
    let isRefreshing: Bool
    
    private var progress: Double {
        guard total > 0 else { return 0 }
        return Double(granted) / Double(total)
    }
    
    private var ringColor: Color {
        if granted == total {
            return .green
        } else if granted == 0 {
            return .gray
        } else {
            return Color.accentColor
        }
    }
    
    var body: some View {
        ZStack {
            // Background ring
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 3)
            
            // Progress ring
            Circle()
                .trim(from: 0, to: progress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress)
            
            // Refresh indicator or checkmark
            if isRefreshing {
                ProgressView()
                    .scaleEffect(0.4)
            } else if granted == total && total > 0 {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.green)
            }
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - Permission Row View

/// Individual permission row with status indicator, action button, and expandable details.
struct PermissionRowView: View {
    let state: PermissionState
    let viewModel: PermissionsViewModel
    /// Callback when user taps the action button (Grant/Manage)
    var onAction: ((PermissionType) -> Void)?
    
    @State private var isHovered = false
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row content
            HStack(spacing: 12) {
                // Disclosure triangle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse details" : "Expand details")
                
                // Icon
                Image(systemName: state.info.icon)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                
                // Name and description
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.info.name)
                        .font(.body)
                        .fontWeight(.medium)
                    
                    Text(state.info.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Status indicator with visual transition on status change
                HStack(spacing: 4) {
                    Image(systemName: state.currentStatus.indicatorIcon)
                        .foregroundStyle(state.currentStatus.indicatorColor)
                        .contentTransition(.symbolEffect(.replace))
                    Text(state.currentStatus.displayLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .animation(.easeInOut(duration: 0.3), value: state.currentStatus)
                
                // Action button with animated label change
                Button(state.currentStatus.actionLabel) {
                    // A policy-restricted permission cannot be granted; its
                    // "View Details" action expands the row details instead
                    // of opening the grant flow.
                    if state.currentStatus == .restricted {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded = true
                        }
                    } else {
                        onAction?(state.type)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .animation(.easeInOut(duration: 0.2), value: state.currentStatus.actionLabel)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            
            // Expanded detail section
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                        .padding(.horizontal, 12)
                    
                    Text(state.info.type.detailedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.leading, 44) // Align with text after icon
                        .padding(.bottom, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(isHovered ? 0.8 : 0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - All Permissions Granted View

/// Celebratory state shown when all permissions have been granted.
struct AllPermissionsGrantedView: View {
    let viewModel: PermissionsViewModel
    @State private var isAnimating = false
    @State private var showRevocationGuide = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image("permissions_complete")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 100, height: 100)
                    .scaleEffect(isAnimating ? 1.05 : 1.0)
                    .animation(
                        .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                        value: isAnimating
                    )
                    .padding(.top, 24)

                VStack(spacing: 8) {
                    Text("All Set!")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("All permissions have been granted")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 12) {
                    GrantedCapabilityView(
                        icon: "mic",
                        title: "Microphone",
                        description: "Console can hear your voice commands"
                    )

                    GrantedCapabilityView(
                        icon: "accessibility",
                        title: "Accessibility",
                        description: "Console can control your Mac on your behalf"
                    )

                    GrantedCapabilityView(
                        icon: "applescript",
                        title: "App Automation",
                        description: "Console can work with other apps"
                    )

                    GrantedCapabilityView(
                        icon: "waveform",
                        title: "Speech Recognition",
                        description: "Console can understand your speech"
                    )
                }
                .padding(.horizontal, 60)

                Button {
                    showRevocationGuide = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Need to disable something?")
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
        }
        .onAppear {
            isAnimating = true
        }
        .sheet(isPresented: $showRevocationGuide) {
            RevocationGuideSheet()
        }
    }
}

// MARK: - Revocation Guide Sheet

/// Sheet explaining how to revoke permissions via System Settings.
private struct RevocationGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Managing Permissions")
                    .font(.headline)
                Spacer()
                CloseButton { dismiss() }
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Introduction
                    Text("You're always in control. Any permission you've granted can be revoked at any time through macOS System Settings.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    
                    // Steps
                    VStack(alignment: .leading, spacing: 16) {
                        RevocationStepView(
                            number: 1,
                            title: "Open System Settings",
                            description: "Click the Apple menu () → System Settings, or search for \"System Settings\" in Spotlight."
                        )
                        
                        RevocationStepView(
                            number: 2,
                            title: "Go to Privacy & Security",
                            description: "In the sidebar, click \"Privacy & Security\" to see all permission categories."
                        )
                        
                        RevocationStepView(
                            number: 3,
                            title: "Find the permission",
                            description: "Click on the permission type you want to manage (e.g., Screen Recording, Accessibility, Files and Folders)."
                        )
                        
                        RevocationStepView(
                            number: 4,
                            title: "Toggle Console off",
                            description: "Find Console in the list and toggle the switch off. The change takes effect immediately."
                        )
                    }
                    
                    // Note
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        
                        Text("Some features may stop working after revoking a permission. You can always re-enable permissions later if needed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    // Action buttons
                    HStack(spacing: 12) {
                        CapsuleButton("Open Privacy & Security") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                        }
                        
                        CapsuleButton("Close", style: .neutral) {
                            dismiss()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(24)
            }
        }
        .frame(width: 480, height: 580)
    }
}

/// Individual step in the revocation guide.
private struct RevocationStepView: View {
    let number: Int
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Individual capability shown in the all-granted view.
private struct GrantedCapabilityView: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Permissions Welcome View

/// Welcome state shown on first visit to permissions view.
struct PermissionsWelcomeView: View {
    let onGetStarted: () -> Void
    @State private var isAnimating = false
    @State private var showLearnMore = false
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Animated shield icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 120, height: 120)
                    .scaleEffect(isAnimating ? 1.1 : 1.0)
                    .animation(
                        .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                        value: isAnimating
                    )
                
                Image(systemName: "lock.shield")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
            }
            
            // Title and explanation
            VStack(spacing: 12) {
                Text("Permissions")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Console asks for permissions as you use features")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                Text("You're always in control. Grant only what you need, when you need it.")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            // Key points
            VStack(alignment: .leading, spacing: 16) {
                WelcomePointView(
                    icon: "hand.raised",
                    title: "You Decide",
                    description: "Each permission is requested individually with clear explanation"
                )
                
                WelcomePointView(
                    icon: "arrow.uturn.backward",
                    title: "Always Reversible",
                    description: "Revoke any permission at any time from System Settings"
                )
                
                WelcomePointView(
                    icon: "eye",
                    title: "Full Transparency",
                    description: "See exactly what each permission enables"
                )
            }
            .padding(.horizontal, 60)
            
            Spacer()
            
            // Get Started button
            Button(action: onGetStarted) {
                Text("Get Started")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            
            // Learn More link
            Button {
                showLearnMore = true
            } label: {
                HStack(spacing: 4) {
                    Text("Learn More")
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                }
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isAnimating = true
        }
        .sheet(isPresented: $showLearnMore) {
            PermissionsPhilosophySheet()
        }
    }
}

// MARK: - Permissions Philosophy Sheet

/// Sheet explaining Console's permissions philosophy in detail.
private struct PermissionsPhilosophySheet: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Our Permissions Philosophy")
                    .font(.headline)
                Spacer()
                CloseButton { dismiss() }
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PhilosophyPrincipleView(
                        number: 1,
                        title: "Never Surprise You",
                        description: "We always show an explanation before macOS asks for permission. You'll never see a system prompt without understanding why it appeared."
                    )
                    
                    PhilosophyPrincipleView(
                        number: 2,
                        title: "One at a Time",
                        description: "Each permission is a separate, focused request. We never batch multiple permissions together, so you can make informed decisions about each one."
                    )
                    
                    PhilosophyPrincipleView(
                        number: 3,
                        title: "Explain Before Asking",
                        description: "Before any system prompt, we tell you what the permission enables, when it's used, and provide step-by-step instructions."
                    )
                    
                    PhilosophyPrincipleView(
                        number: 4,
                        title: "Show Current State",
                        description: "You can always see which permissions are granted at a glance. The status updates in real-time when you change settings."
                    )
                    
                    PhilosophyPrincipleView(
                        number: 5,
                        title: "Always Reversible",
                        description: "Every permission can be revoked. We provide clear guidance on how to disable any permission you've granted."
                    )
                    
                    PhilosophyPrincipleView(
                        number: 6,
                        title: "Full Transparency",
                        description: "No hidden data collection. Plain language descriptions. You always know exactly what Console can do with each permission."
                    )
                }
                .padding(24)
            }
        }
        .frame(width: 500, height: 550)
    }
}

/// Individual principle in the philosophy sheet.
private struct PhilosophyPrincipleView: View {
    let number: Int
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Individual point in the welcome view.
private struct WelcomePointView: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Previews

#Preview("Welcome State") {
    PermissionsWelcomeView(onGetStarted: {})
        .frame(width: 600, height: 700)
}

#Preview("Standard Width") {
    PermissionsView()
        .frame(width: 600, height: 700)
}

#Preview("Narrow Width - Text Truncation") {
    PermissionsView()
        .frame(width: 400, height: 700)
}

#Preview("Wide Width") {
    PermissionsView()
        .frame(width: 900, height: 700)
}

#Preview("Single Row - All Statuses") {
    VStack(spacing: 12) {
        PermissionRowView(
            state: PermissionState(type: .microphone, status: .granted),
            viewModel: PermissionsViewModel()
        )
        PermissionRowView(
            state: PermissionState(type: .automation, status: .notGranted),
            viewModel: PermissionsViewModel()
        )
        PermissionRowView(
            state: PermissionState(type: .accessibility, status: .denied),
            viewModel: PermissionsViewModel()
        )
        PermissionRowView(
            state: PermissionState(type: .speechRecognition, status: .restricted),
            viewModel: PermissionsViewModel()
        )
    }
    .padding()
    .frame(width: 500)
}
