import Foundation

struct Config {
    /// Scroll speed in points per second.
    var scrollSpeed: Double = 40
    /// Maximum number of images randomly selected from the chosen folder.
    var maxImages: Int = 500

    /// Load config from ~/Library/Application Support/SlideshowVibe/config.json.
    /// Creates the file with defaults on first run so users know where to find it.
    static func load() -> Config {
        let defaults = Config()
        guard let url = configFileURL else { return defaults }

        if !FileManager.default.fileExists(atPath: url.path) {
            writeDefaults(to: url, config: defaults)
            return defaults
        }

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return defaults }

        var config = Config()
        if let v = json["scrollSpeed"] as? Double { config.scrollSpeed = max(1, v) }
        if let v = json["maxImages"] as? Int      { config.maxImages   = max(1, v) }
        return config
    }

    private static var configFileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SlideshowVibe/config.json")
    }

    private static func writeDefaults(to url: URL, config: Config) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = ["scrollSpeed": config.scrollSpeed,
                                   "maxImages":   config.maxImages]
        if let data = try? JSONSerialization.data(withJSONObject: json,
                                                  options: .prettyPrinted) {
            try? data.write(to: url)
        }
    }
}
