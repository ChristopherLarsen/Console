import AppKit

final class AppIconResolver {
    static let shared = AppIconResolver()

    private let maxCacheSize = 50
    private var cache: [String: NSImage] = [:]
    private var accessOrder: [String] = []

    private init() {}

    func getIcon(for bundleID: String, size: CGFloat = 32) -> NSImage {
        let cacheKey = "\(bundleID)@\(Int(size))"
        if let cached = cache[cacheKey] {
            promoteInAccessOrder(cacheKey)
            return cached
        }

        let icon: NSImage
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let appIcon = loadIcon(from: appURL) {
            icon = resizeIcon(appIcon, to: size)
        } else {
            icon = fallbackIcon(size: size)
        }

        insertIntoCache(cacheKey, image: icon)
        return icon
    }

    func resizeIcon(_ image: NSImage, to size: CGFloat) -> NSImage {
        let newImage = NSImage(size: NSSize(width: size, height: size))
        newImage.lockFocus()
        image.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }

    // MARK: - Private

    private func loadIcon(from appURL: URL) -> NSImage? {
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        guard icon.size.width > 0 else { return nil }
        return icon
    }

    private func fallbackIcon(size: CGFloat) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .regular)
        if let symbol = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            return symbol
        }
        return NSImage(size: NSSize(width: size, height: size))
    }

    // LRU eviction — remove least recently accessed entry when at capacity
    private func insertIntoCache(_ key: String, image: NSImage) {
        if cache.count >= maxCacheSize, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
        cache[key] = image
        accessOrder.append(key)
    }

    private func promoteInAccessOrder(_ key: String) {
        if let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
            accessOrder.append(key)
        }
    }
}
