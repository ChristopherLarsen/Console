import SwiftUI

struct ShowcaseAppRow: View {
    let app: ShowcaseApp

    @State private var appIcon: NSImage?
    @State private var isInstalled: Bool = true
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            iconView
            commandsColumn
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isInstalled ? 1.0 : 0.6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isHovered ? 0.08 : 0), radius: 4, y: 2)
        )
        .scaleEffect(isHovered ? 1.005 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
        .task { await loadIcon() }
    }

    private var rowAccessibilityLabel: String {
        var parts = [app.name]
        if !isInstalled { parts.append("not installed") }
        parts.append("\(app.showcaseCommands.count) voice commands")
        parts.append(contentsOf: app.showcaseCommands)
        return parts.joined(separator: ", ")
    }

    // MARK: - Icon

    private var iconView: some View {
        Group {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: app.iconName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .accessibilityLabel("\(app.name) icon")
    }

    // MARK: - Commands

    private var catalogPatternCount: Int? {
        ActionCatalogManager.shared.findAppEntry(bundleID: app.bundleID)?.commonPatterns.count
    }

    private var commandsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(app.name)
                    .font(.callout.weight(.semibold))

                if !isInstalled {
                    Text("Not Installed")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.1), in: Capsule())
                        .accessibilityLabel("Not installed")
                } else if let count = catalogPatternCount, count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .accessibilityLabel("\(count) catalog patterns")
                }
            }

            FlowLayout(spacing: 6) {
                ForEach(app.showcaseCommands, id: \.self) { command in
                    HStack(spacing: 3) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 8))
                        Text(command)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
                    .accessibilityLabel("Voice command: \(command)")
                }
            }
        }
    }

    private func loadIcon() async {
        let bundleID = app.bundleID
        let (icon, installed) = await Task.detached(priority: .background) {
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            let icon = await AppIconResolver.shared.getIcon(for: bundleID, size: 48)
            return (icon, installed)
        }.value
        appIcon = icon
        isInstalled = installed
    }
}
