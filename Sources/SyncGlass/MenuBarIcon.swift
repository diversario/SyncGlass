import AppKit

/// Cached template symbols. Byte updates never repaint the menu bar.
@MainActor
enum MenuBarIcon {
    enum Symbol: String, CaseIterable {
        case idle = "icloud"
        case uploading = "icloud.and.arrow.up"
        case downloading = "icloud.and.arrow.down"
        case both = "arrow.up.arrow.down"
        case offline = "icloud.slash"
        case unavailable = "exclamationmark.icloud"
        case stuck = "exclamationmark.triangle"
    }

    private static let images: [Symbol: NSImage] = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        return Dictionary(uniqueKeysWithValues: Symbol.allCases.map { symbol in
            let image = NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil)!
                .withSymbolConfiguration(configuration)!
            image.isTemplate = true
            return (symbol, image)
        })
    }()

    static func symbol(for snapshot: TrackerSnapshot, isReachable: Bool, stuckCount: Int = 0) -> Symbol {
        guard isReachable else { return .offline }
        if case .unavailable = snapshot.availability { return .unavailable }
        let directions = snapshot.activeDirections
        if directions.contains([.upload, .download]) { return .both }
        if directions.contains(.upload) { return .uploading }
        if directions.contains(.download) { return .downloading }
        return stuckCount > 0 ? .stuck : .idle
    }

    static func image(for snapshot: TrackerSnapshot, isReachable: Bool, stuckCount: Int = 0) -> NSImage {
        images[symbol(for: snapshot, isReachable: isReachable, stuckCount: stuckCount)]!
    }

    static func accessibilityLabel(for snapshot: TrackerSnapshot, isReachable: Bool, stuckCount: Int = 0) -> String {
        var states: [String] = []
        if !isReachable { states.append("offline") }
        if case .unavailable(let reason) = snapshot.availability {
            states.append("monitoring unavailable: \(reason)")
        }
        let directions = snapshot.activeDirections
        if directions.contains(.upload) { states.append("uploading") }
        if directions.contains(.download) { states.append("downloading") }
        let waiting = snapshot.items.filter { $0.waitingUpload && !$0.active.contains(.upload) }.count
        if waiting > 0 { states.append("\(waiting) waiting to upload") }
        if snapshot.isScanning { states.append("scanning for transfers") }
        if stuckCount > 0 { states.append("\(stuckCount) stuck \(stuckCount == 1 ? "file" : "files")") }
        if states.isEmpty { states.append("no observed transfers") }
        return "SyncGlass: " + states.joined(separator: "; ")
    }
}
