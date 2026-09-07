import Foundation

/// Persists one `MorningBrief` JSON file per calendar day under
/// Application Support/Console/brief/. Content is local-only: commit
/// subjects and the user's own task lines.
struct BriefStore {
    let directory: URL
    private let fileManager: FileManager

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directory = appSupport
                .appendingPathComponent("Console", isDirectory: true)
                .appendingPathComponent("brief", isDirectory: true)
        }
        self.fileManager = fileManager
    }

    static func startOfDay(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    // MARK: - Paths

    func url(forDay day: Date) -> URL {
        directory.appendingPathComponent("brief-\(Self.dayFormatter.string(from: day)).json")
    }

    // MARK: - Load

    func load(forDay day: Date) -> MorningBrief? {
        guard let data = try? Data(contentsOf: url(forDay: day)) else { return nil }
        return try? JSONDecoder().decode(MorningBrief.self, from: data)
    }

    /// The most recent brief stored strictly before `day`, for carrying
    /// today's tasks forward.
    func loadMostRecent(before day: Date, calendar: Calendar = .current) -> MorningBrief? {
        let dayStart = Self.startOfDay(for: day, calendar: calendar)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return nil }

        let briefs = entries.compactMap { entry -> MorningBrief? in
            let name = entry.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("brief-") else { return nil }
            let dateString = name.dropFirst("brief-".count)
            guard let fileDay = Self.dayFormatter.date(from: String(dateString)),
                  fileDay < dayStart else { return nil }
            return load(forDay: fileDay)
        }
        return briefs.max(by: { $0.day < $1.day })
    }

    // MARK: - Save

    /// Throws on write failure — callers must surface the error instead of
    /// letting a failed persist masquerade as success.
    func save(_ brief: MorningBrief) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(brief)
        try data.write(to: url(forDay: brief.day), options: .atomic)
    }
}
