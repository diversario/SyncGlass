import Foundation

struct TransferDirections: OptionSet, Sendable {
    let rawValue: UInt8
    static let upload = Self(rawValue: 1)
    static let download = Self(rawValue: 2)
}

enum TransferDirection: String, CaseIterable, Sendable {
    case upload, download

    var flag: TransferDirections { self == .upload ? .upload : .download }
    var title: String { self == .upload ? "Uploads" : "Downloads" }
}

struct TransferItem: Identifiable, Equatable, Sendable {
    var path: String
    var active: TransferDirections = []
    var waitingUpload = false
    var error: String?

    var id: String { path }
    func belongs(to direction: TransferDirection) -> Bool {
        active.contains(direction.flag) || (direction == .upload && waitingUpload)
    }
}

enum MonitorAvailability: Equatable, Sendable {
    case ready
    case unavailable(String)
}

struct TrackerSnapshot: Equatable, Sendable {
    var items: [TransferItem] = []
    var availability: MonitorAvailability = .ready
    var isScanning = false

    var activeDirections: TransferDirections {
        items.reduce(into: TransferDirections()) { $0.formUnion($1.active) }
    }
}
