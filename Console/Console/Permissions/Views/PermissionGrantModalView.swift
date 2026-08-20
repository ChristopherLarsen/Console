import SwiftUI
import AppKit
import Combine


/// Modal view displayed when user wants to grant a specific permission.
/// Shows what the permission does, when it's used, and step-by-step instructions.
struct PermissionGrantModalView: View {
    let permissionType: PermissionType
    let onDismiss: () -> Void
    let onGrant: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with dismiss button
            modalHeader
            
            Divider()
            
            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Permission icon and title
                    permissionHeader
                    
                    // Section 1: What this permission does
                    whatSection
                    
                    // Section 2: When it's used
                    whenSection
                    
                    // Section 3: Your control
                    controlSection
                    
                    // Section 4: Step-by-step instructions
                    instructionsSection
                    
                    // Section 5: Privacy reassurance (placeholder for B6)
                    // privacySection
                }
                .padding(24)
            }
            
            Divider()
            
            // Footer with action buttons
            modalFooter
        }
        .frame(width: 480, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission request for \(permissionType.displayName)")
    }
    
    // MARK: - Header
    
    private var modalHeader: some View {
        HStack {
            Text("Permission Required")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            
            Spacer()
            
            CloseButton { onDismiss() }
        }
        .padding()
    }
    
    // MARK: - Permission Header
    
    private var permissionHeader: some View {
        HStack(spacing: 16) {
            // Permission icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 60, height: 60)
                
                Image(systemName: permissionType.icon)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(permissionType.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(permissionType.shortDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - What Section
    
    private var whatSection: some View {
        PermissionModalWhatSection(permissionType: permissionType)
    }
    
    // MARK: - When Section
    
    private var whenSection: some View {
        PermissionModalWhenSection(permissionType: permissionType)
    }
    
    // MARK: - Control Section
    
    private var controlSection: some View {
        PermissionModalControlSection(permissionType: permissionType, onOverview: onDismiss)
    }
    
    // MARK: - Instructions Section
    
    private var instructionsSection: some View {
        PermissionModalInstructionsSection(permissionType: permissionType)
    }
    
    // MARK: - Footer
    
    private var modalFooter: some View {
        VStack(spacing: 12) {
            // Explanatory text about what the button does
            Text(permissionType.grantButtonExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            HStack {
                Button("Not Now") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.buttonNeutralBackgroundColor)
                .controlSize(.large)
                
                Spacer()
                
                Button {
                    onGrant()
                } label: {
                    Label("Grant Permission", systemImage: "checkmark.shield")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .controlSize(.large)
            }
        }
        .padding()
    }
}

// MARK: - PermissionType Extensions for Modal Content

extension PermissionType {
    /// Usage examples shown in the "What" section.
    var usageExamples: [String] {
        switch self {
        case .microphone:
            return [
                "Say \"Console, what's on my schedule today?\"",
                "Dictate notes instead of typing them out",
                "Give voice commands while your hands are busy"
            ]
        case .accessibility:
            return [
                "Ask Console to fill out a repetitive form for you",
                "Have Console click through a multi-step setup wizard",
                "Let Console rename and organize files in Finder"
            ]
        case .automation:
            return [
                "Ask Console to move selected emails to a folder",
                "Have Console create a calendar event from an email",
                "Let Console export data from one app to another"
            ]
        case .speechRecognition:
            return [
                "Speak naturally and see your words transcribed in real time",
                "Dictate notes or messages hands-free",
                "Use voice commands for app control"
            ]
        }
    }
    
    /// Description of when the permission is used.
    var whenUsedDescription: String {
        switch self {
        case .microphone:
            return "Only when you activate voice input. Console listens only during active voice sessions and never records audio in the background."
        case .accessibility:
            return "When you ask Console to interact with your Mac's interface. This enables clicking, typing, and navigating apps on your behalf."
        case .automation:
            return "When you ask Console to control or communicate with other applications. This lets Console work with multiple apps together to get things done."
        case .speechRecognition:
            return "Only when you enable live speech recognition. Audio is processed on-device and is never sent to external servers."
        }
    }
}

// MARK: - Permission Modal What Section

/// Reusable component showing what a permission does with examples.
struct PermissionModalWhatSection: View {
    let permissionType: PermissionType
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("What this permission does", systemImage: "lightbulb")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                
                Spacer()
                
                Image(systemName: permissionType.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor.opacity(0.6))
                    .accessibilityHidden(true)
            }
            
            Text(permissionType.detailedDescription)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            // Concrete examples of when permission is used
            VStack(alignment: .leading, spacing: 8) {
                ForEach(permissionType.usageExamples, id: \.self) { example in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(example)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Examples: \(permissionType.usageExamples.joined(separator: ". "))")
        }
        .padding()
        .accessibilityElement(children: .contain)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Permission Modal When Section

/// Reusable component showing when a permission is used.
struct PermissionModalWhenSection: View {
    let permissionType: PermissionType
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("When it's used", systemImage: "clock")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                
                Spacer()
                
                Image(systemName: permissionType.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor.opacity(0.6))
                    .accessibilityHidden(true)
            }
            
            Text(permissionType.whenUsedDescription)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Permission Modal Control Section

/// Reusable component emphasizing user control over permissions.
struct PermissionModalControlSection: View {
    let permissionType: PermissionType
    let onOverview: () -> Void
    @State private var showRevokeInfo = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("You're in control", systemImage: "slider.horizontal.3")
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                Spacer()
                
                Image(systemName: permissionType.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor.opacity(0.6))
            }
            
            // Reversibility message
            Text("You can change this anytime in System Settings. Console will still work without this permission—some features just won't be available.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            // Expandable "What if I revoke this?" section
            DisclosureGroup(isExpanded: $showRevokeInfo) {
                Text(permissionType.revokeConsequences)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                Text("What if I revoke this later?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            
            // Action links
            HStack(spacing: 16) {
                // Tappable link to open System Settings
                Button {
                    if let url = permissionType.systemSettingsURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gear")
                            .font(.system(size: 12))
                        Text("Open in System Settings")
                            .font(.callout)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Open System Settings to manage this permission")
                
                // Link to return to permissions overview
                Button {
                    onOverview()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 12))
                        Text("View All Permissions")
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Return to permissions overview")
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Permission Modal Instructions Section

/// Reusable component showing step-by-step instructions for granting permission.
struct PermissionModalInstructionsSection: View {
    let permissionType: PermissionType
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("How to grant", systemImage: "list.number")
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                Spacer()
                
                Image(systemName: permissionType.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor.opacity(0.6))
            }
            
            // Numbered steps
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(permissionType.grantInstructions.enumerated()), id: \.offset) { index, instruction in
                    HStack(alignment: .top, spacing: 10) {
                        // Step number in circle
                        Text("\(index + 1)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Color.accentColor)
                            .clipShape(Circle())
                        
                        Text(instruction)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Permission Modal Waiting View

/// View displayed while waiting for user to grant permission in System Settings.
struct PermissionModalWaitingView: View {
    let permissionType: PermissionType
    let checkPermission: () async -> PermissionStatus
    let onPermissionGranted: () -> Void
    let onCancel: () -> Void
    let onOpenSettings: () -> Void
    
    private let timeoutSeconds = 30
    
    @State private var dotCount = 0
    @State private var pollCount = 0
    @State private var showTimeoutMessage = false
    
    private let animationTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private let pollingTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Animated progress indicator
            ProgressView()
                .scaleEffect(1.5)
                .padding(.bottom, 8)
            
            // Waiting message with animated dots
            Text("Waiting for permission\(String(repeating: ".", count: dotCount))")
                .font(.title2)
                .fontWeight(.semibold)
                .onReceive(animationTimer) { _ in
                    dotCount = (dotCount + 1) % 4
                }
            
            // Timeout message (shown after 30 seconds)
            if showTimeoutMessage {
                Text("Still waiting... Make sure you've enabled Console in System Settings.")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .transition(.opacity)
            }
            
            // Instruction reminder
            VStack(spacing: 8) {
                Text("If System Settings opened, follow these steps:")
                    .font(.body)
                    .foregroundStyle(.secondary)
                
                Text("Find \"\(permissionType.displayName)\" and turn on Console")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            
            // Status indicator with poll count
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Checking again... (\(pollCount)s)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .onReceive(pollingTimer) { _ in
                pollCount += 1
                // Show timeout message after threshold
                if pollCount >= timeoutSeconds && !showTimeoutMessage {
                    withAnimation {
                        showTimeoutMessage = true
                    }
                }
                Task {
                    let status = await checkPermission()
                    if status == .granted {
                        await MainActor.run {
                            onPermissionGranted()
                        }
                    }
                }
            }
            
            Spacer()
            
            // Action buttons
            VStack(spacing: 12) {
                Button {
                    onOpenSettings()
                } label: {
                    Label("Open System Settings Again", systemImage: "gear")
                }
                .buttonStyle(.bordered)
                
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, 24)
        }
        .frame(width: 400, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            // Initial check on appear
            Task {
                let status = await checkPermission()
                if status == .granted {
                    await MainActor.run {
                        onPermissionGranted()
                    }
                }
            }
        }
    }
}

// MARK: - Permission Modal Success View

/// View displayed after permission has been successfully granted.
struct PermissionModalSuccessView: View {
    let permissionType: PermissionType
    let onDone: () -> Void
    var autoDismissSeconds: Int = 3
    
    @State private var showCheckmark = false
    @State private var countdown: Int = 3
    @State private var autoDismissTask: Task<Void, Never>?
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Checkmark with scale animation
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 160, height: 160)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 100))
                    .foregroundStyle(.green)
                    .scaleEffect(showCheckmark ? 1.0 : 0.5)
                    .opacity(showCheckmark ? 1.0 : 0.0)
            }
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    showCheckmark = true
                }
            }
            
            // Success message
            VStack(spacing: 8) {
                Text("Permission Granted")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("\(permissionType.displayName) is now enabled")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            
            // What's now possible
            VStack(spacing: 8) {
                Text("You can now")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                
                Text(permissionType.grantedCapabilities)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color.green.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            Spacer()
            
            // Done button with auto-dismiss countdown
            VStack(spacing: 8) {
                Button {
                    autoDismissTask?.cancel()
                    onDone()
                } label: {
                    Text("Done")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .padding(.horizontal, 40)
                
                // Auto-dismiss countdown indicator
                Text("Closing in \(countdown)...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 24)
        }
        .frame(width: 400, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            countdown = autoDismissSeconds
            startAutoDismiss()
        }
        .onDisappear {
            autoDismissTask?.cancel()
        }
    }
    
    private func startAutoDismiss() {
        autoDismissTask = Task {
            for i in (1...autoDismissSeconds).reversed() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    countdown = i - 1
                }
            }
            if !Task.isCancelled {
                await MainActor.run {
                    onDone()
                }
            }
        }
    }
}

// MARK: - Permission Modal Failure View

/// View displayed when permission request is cancelled or fails.
struct PermissionModalFailureView: View {
    let permissionType: PermissionType
    let onTryAgain: () -> Void
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    
    @State private var showWhyHelps = false
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            // Neutral icon (not error/warning)
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "xmark.circle")
                    .font(.system(size: 50))
                    .foregroundStyle(.secondary)
            }
            
            // Calm message (no blame)
            VStack(spacing: 8) {
                Text("Permission Not Granted")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("No problem—you can grant this anytime.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            
            // Reassurance with "Learn why" expandable
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 4) {
                    Text("Console still works without this permission")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    
                    Text("Some features just won't be available.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                
                // "Learn Why This Helps" disclosure
                DisclosureGroup(isExpanded: $showWhyHelps) {
                    Text(permissionType.detailedDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                } label: {
                    Text("Learn why this helps")
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 24)
            
            Spacer()
            
            // Action buttons
            VStack(spacing: 12) {
                Button {
                    onTryAgain()
                } label: {
                    Text("Try Again")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .controlSize(.large)
                
                Button {
                    onOpenSettings()
                } label: {
                    Label("Open System Settings", systemImage: "gear")
                }
                .buttonStyle(.bordered)
                
                Button("Not Now") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .frame(width: 400, height: 450)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Permission Manage Modal View

/// View displayed when user wants to manage an already-granted permission.
struct PermissionManageModalView: View {
    let permissionType: PermissionType
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    
    @State private var showDisableSteps = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Manage Permission")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                
                Spacer()
                
                CloseButton { onDismiss() }
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Status indicator
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.15))
                                .frame(width: 50, height: 50)
                            
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.green)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(permissionType.displayName)")
                                .font(.title3)
                                .fontWeight(.semibold)
                            
                            Text("This permission is enabled")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        }
                    }
                    
                    // Current capability
                    VStack(alignment: .leading, spacing: 8) {
                        Label("What's enabled", systemImage: "checkmark.shield")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        
                        Text("Console can \(permissionType.grantedCapabilities).")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    // How to disable
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Your control", systemImage: "slider.horizontal.3")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        
                        Text("You can disable this anytime in System Settings.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        
                        // Expandable disable steps
                        DisclosureGroup(isExpanded: $showDisableSteps) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(disableInstructions.enumerated()), id: \.offset) { index, instruction in
                                    HStack(alignment: .top, spacing: 10) {
                                        Text("\(index + 1)")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.white)
                                            .frame(width: 20, height: 20)
                                            .background(Color.secondary)
                                            .clipShape(Circle())
                                        
                                        Text(instruction)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("How to disable this permission")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    // Re-enable note
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.left.circle")
                            .foregroundStyle(.tertiary)
                        Text("To turn this back on, return here and click \"Grant Permission\".")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(24)
            }
            
            Divider()
            
            // Footer
            HStack {
                Button {
                    onOpenSettings()
                } label: {
                    Label("Open System Settings", systemImage: "gear")
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
            }
            .padding()
        }
        .frame(width: 450, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var disableInstructions: [String] {
        [
            "Open System Settings",
            "Go to Privacy & Security",
            "Find \"\(permissionType.displayName)\" in the list",
            "Turn off the switch next to Console",
            "Return to Console when finished"
        ]
    }
}

// MARK: - Preview

#Preview("Accessibility") {
    PermissionGrantModalView(
        permissionType: .accessibility,
        onDismiss: {},
        onGrant: {}
    )
    .padding(40)
    .background(Color.black.opacity(0.4))
}

#Preview("Microphone") {
    PermissionGrantModalView(
        permissionType: .microphone,
        onDismiss: {},
        onGrant: {}
    )
    .padding(40)
    .background(Color.black.opacity(0.4))
}

#Preview("Waiting State") {
    PermissionModalWaitingView(
        permissionType: .microphone,
        checkPermission: { .notGranted },
        onPermissionGranted: {},
        onCancel: {},
        onOpenSettings: {}
    )
    .padding(40)
    .background(Color.black.opacity(0.4))
}

#Preview("Success State") {
    PermissionModalSuccessView(
        permissionType: .microphone,
        onDone: {}
    )
    .padding(40)
    .background(Color.black.opacity(0.4))
}

#Preview("Failure State") {
    PermissionModalFailureView(
        permissionType: .microphone,
        onTryAgain: {},
        onDismiss: {},
        onOpenSettings: {}
    )
    .padding(40)
    .background(Color.black.opacity(0.4))
}

#Preview("Manage Permission") {
    PermissionManageModalView(
        permissionType: .microphone,
        onDismiss: {},
        onOpenSettings: {}
    )
    .padding(40)
    .background(Color.black.opacity(0.4))
}
