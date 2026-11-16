import Foundation

/// Only paths whose transfer state still needs a metadata recheck are persisted.
/// Existing history files are deliberately left untouched.
enum InFlightTransfersStore {
    static var url: URL { Paths.supportFolder.appendingPathComponent("transfers_in_flight.plist") }

    static func load() -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? PropertyListDecoder().decode([String].self, from: data)) ?? []
    }

    static func save(_ paths: Set<String>) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        guard let data = try? encoder.encode(paths.sorted()) else { return }
        try? FileManager.default.createDirectory(at: Paths.supportFolder, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
