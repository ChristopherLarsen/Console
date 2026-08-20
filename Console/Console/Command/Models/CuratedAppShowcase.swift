import Foundation

enum AppCategory: String, CaseIterable, Identifiable {
    case all
    case productivity
    case communication
    case development
    case creative
    case browsers

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .productivity: return "Productivity"
        case .communication: return "Communication"
        case .development: return "Development"
        case .creative: return "Creative"
        case .browsers: return "Browsers"
        }
    }
}

struct ShowcaseApp: Identifiable {
    let id: String
    let name: String
    let bundleID: String
    let iconName: String
    let showcaseCommands: [String]
    let popularityRank: Int
    let category: AppCategory
}

final class CuratedAppShowcase {

    // Curated list of 20 popular macOS apps with representative commands
    static let apps: [ShowcaseApp] = [
        // Rank 1-5
        ShowcaseApp(
            id: "safari", name: "Safari", bundleID: "com.apple.Safari",
            iconName: "safari", showcaseCommands: [
                "Open a URL", "New tab", "Get current URL", "Close tab",
            ], popularityRank: 1, category: .browsers
        ),
        ShowcaseApp(
            id: "finder", name: "Finder", bundleID: "com.apple.finder",
            iconName: "folder", showcaseCommands: [
                "Open folder", "New folder", "Empty trash", "Open downloads",
            ], popularityRank: 2, category: .productivity
        ),
        ShowcaseApp(
            id: "mail", name: "Mail", bundleID: "com.apple.mail",
            iconName: "envelope", showcaseCommands: [
                "Compose email", "Check email", "Get unread count",
            ], popularityRank: 3, category: .communication
        ),
        ShowcaseApp(
            id: "calendar", name: "Calendar", bundleID: "com.apple.iCal",
            iconName: "calendar", showcaseCommands: [
                "Create event", "Get today's events", "Open calendar",
            ], popularityRank: 4, category: .productivity
        ),
        ShowcaseApp(
            id: "messages", name: "Messages", bundleID: "com.apple.MobileSMS",
            iconName: "message", showcaseCommands: [
                "Send message", "Open messages",
            ], popularityRank: 5, category: .communication
        ),

        // Rank 6-10
        ShowcaseApp(
            id: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome",
            iconName: "globe", showcaseCommands: [
                "Open URL", "New tab", "Close tab", "Reload page", "Get current URL",
            ], popularityRank: 6, category: .browsers
        ),
        ShowcaseApp(
            id: "slack", name: "Slack", bundleID: "com.tinyspeck.slackmacgap",
            iconName: "number", showcaseCommands: [
                "Open channel", "Send message", "Set status",
            ], popularityRank: 7, category: .communication
        ),
        ShowcaseApp(
            id: "spotify", name: "Spotify", bundleID: "com.spotify.client",
            iconName: "music.note", showcaseCommands: [
                "Play", "Pause", "Next track", "Previous track", "Now playing",
            ], popularityRank: 8, category: .creative
        ),
        ShowcaseApp(
            id: "notes", name: "Notes", bundleID: "com.apple.Notes",
            iconName: "note.text", showcaseCommands: [
                "Create note", "Open notes",
            ], popularityRank: 9, category: .productivity
        ),
        ShowcaseApp(
            id: "zoom", name: "Zoom", bundleID: "us.zoom.xos",
            iconName: "video", showcaseCommands: [
                "Start meeting", "Join meeting", "Mute microphone",
            ], popularityRank: 10, category: .communication
        ),

        // Rank 11-15
        ShowcaseApp(
            id: "notion", name: "Notion", bundleID: "notion.id",
            iconName: "doc.text", showcaseCommands: [
                "Create page", "Open workspace", "Search",
            ], popularityRank: 11, category: .productivity
        ),
        ShowcaseApp(
            id: "vscode", name: "VS Code", bundleID: "com.microsoft.VSCode",
            iconName: "chevron.left.forwardslash.chevron.right", showcaseCommands: [
                "Open file", "New terminal", "Toggle sidebar",
            ], popularityRank: 12, category: .development
        ),
        ShowcaseApp(
            id: "terminal", name: "Terminal", bundleID: "com.apple.Terminal",
            iconName: "terminal", showcaseCommands: [
                "Run command", "Open new window", "Run in current session",
            ], popularityRank: 13, category: .development
        ),
        ShowcaseApp(
            id: "word", name: "Microsoft Word", bundleID: "com.microsoft.Word",
            iconName: "doc.richtext", showcaseCommands: [
                "New document", "Open file", "Save document",
            ], popularityRank: 14, category: .productivity
        ),
        ShowcaseApp(
            id: "excel", name: "Microsoft Excel", bundleID: "com.microsoft.Excel",
            iconName: "tablecells", showcaseCommands: [
                "New spreadsheet", "Open workbook", "Save workbook",
            ], popularityRank: 15, category: .productivity
        ),

        // Rank 16-20
        ShowcaseApp(
            id: "photoshop", name: "Photoshop", bundleID: "com.adobe.Photoshop",
            iconName: "paintbrush", showcaseCommands: [
                "Open image", "Export as PNG", "New document",
            ], popularityRank: 16, category: .creative
        ),
        ShowcaseApp(
            id: "figma", name: "Figma", bundleID: "com.figma.Desktop",
            iconName: "pencil.and.ruler", showcaseCommands: [
                "Open file", "Create frame", "Export selection",
            ], popularityRank: 17, category: .creative
        ),
        ShowcaseApp(
            id: "discord", name: "Discord", bundleID: "com.hnc.Discord",
            iconName: "bubble.left.and.bubble.right", showcaseCommands: [
                "Open server", "Join voice channel", "Send message",
            ], popularityRank: 18, category: .communication
        ),
        ShowcaseApp(
            id: "1password", name: "1Password", bundleID: "com.1password.1password",
            iconName: "lock.shield", showcaseCommands: [
                "Search vault", "Copy password", "Lock vault",
            ], popularityRank: 19, category: .productivity
        ),
        ShowcaseApp(
            id: "docker", name: "Docker", bundleID: "com.docker.docker",
            iconName: "shippingbox", showcaseCommands: [
                "Start container", "Stop container", "List containers",
            ], popularityRank: 20, category: .development
        ),
    ]

    static var sortedByPopularity: [ShowcaseApp] {
        apps.sorted { $0.popularityRank < $1.popularityRank }
    }
}
