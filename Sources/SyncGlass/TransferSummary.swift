import Foundation

struct DirectionSummary: Equatable {
    let items: [TransferItem]
    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var unavailableCount = 0
    private(set) var overflowed = false

    init(items: [TransferItem], direction: TransferDirection, progress: [String: FileProgress]) {
        self.items = items.filter { $0.belongs(to: direction) }
        updateProgress(direction: direction, progress: progress)
    }

    var fileCount: Int { items.count }
    var fraction: Double? {
        guard unavailableCount == 0, !overflowed else { return nil }
        return totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0
    }
    var byteText: String {
        guard !overflowed else { return "Byte total unavailable" }
        let counts = "\(Self.bytes(completedBytes)) / \(Self.bytes(totalBytes))"
        return unavailableCount == 0 ? counts : "Reported: \(counts)"
    }
    var availabilityText: String? {
        if overflowed { return "Byte total unavailable" }
        guard unavailableCount > 0 else { return nil }
        return "Progress unavailable for \(unavailableCount) \(unavailableCount == 1 ? "file" : "files"); byte total unavailable"
    }

    mutating func updateProgress(direction: TransferDirection, progress: [String: FileProgress]) {
        completedBytes = 0
        totalBytes = 0
        unavailableCount = 0
        overflowed = false
        for item in items {
            guard let p = progress[item.path], p.matches(item, direction: direction) else {
                unavailableCount += 1
                continue
            }
            let current = completedBytes.addingReportingOverflow(min(p.completedBytes, p.totalBytes))
            let total = totalBytes.addingReportingOverflow(p.totalBytes)
            if current.overflow || total.overflow {
                overflowed = true
            } else if !overflowed {
                completedBytes = current.partialValue
                totalBytes = total.partialValue
            }
        }
    }

    static func bytes(_ count: Int64) -> String {
        if count == 0 { return "0 B" }
        return count.formatted(.byteCount(style: .file))
    }
}
