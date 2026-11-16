import Foundation

/// Byte counts published for one file operation.
struct FileProgress: Equatable {
    enum Direction { case uploading, downloading }

    var direction: Direction?
    var fraction: Double
    var completedBytes: Int64
    var totalBytes: Int64

    static func read(_ progress: Progress) -> FileProgress? {
        guard progress.kind == .file, !progress.isIndeterminate, !progress.isCancelled,
              progress.totalUnitCount > 0, progress.completedUnitCount >= 0 else { return nil }
        let direction: Direction?
        switch progress.fileOperationKind {
        case .uploading?: direction = .uploading
        case .downloading?: direction = .downloading
        default: direction = nil
        }
        let total = progress.totalUnitCount
        let completed = min(total, progress.completedUnitCount)
        return Self(direction: direction, fraction: Double(completed) / Double(total),
                    completedBytes: completed, totalBytes: total)
    }

    func matches(_ item: TransferItem, direction: TransferDirection) -> Bool {
        guard totalBytes > 0, completedBytes >= 0, item.active.contains(direction.flag) else { return false }
        switch self.direction {
        case .uploading?: return direction == .upload
        case .downloading?: return direction == .download
        case nil: return item.active == direction.flag
        }
    }
}

/// Subscriptions exist only while a panel or an on-demand file window needs them.
final class FileProgressMonitor: @unchecked Sendable {
    static let maxSubscriptions = 500

    private struct Entry {
        let generation: UUID
        var token: Any?
        var progress: Progress?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    deinit { track([String]()) }

    var subscriptionCount: Int { withLock { entries.count } }

    func track(_ paths: Set<String>) { track(paths.sorted()) }

    /// Earlier paths get priority when the subscription ceiling is reached.
    func track(_ paths: [String]) {
        var wanted = Set<String>()
        var ordered: [String] = []
        for path in paths where wanted.count < Self.maxSubscriptions {
            if wanted.insert(path).inserted { ordered.append(path) }
        }
        let removed: [Any] = withLock {
            let stale = entries.keys.filter { !wanted.contains($0) }
            return stale.compactMap { entries.removeValue(forKey: $0)?.token }
        }
        removed.forEach(Progress.removeSubscriber)
        for path in ordered {
            let generation = UUID()
            let added = withLock {
                guard entries[path] == nil else { return false }
                entries[path] = Entry(generation: generation)
                return true
            }
            guard added else { continue }
            let token = Progress.addSubscriber(forFileURL: URL(fileURLWithPath: path)) { [weak self] progress in
                self?.withLock {
                    guard self?.entries[path]?.generation == generation else { return }
                    self?.entries[path]?.progress = progress
                }
                return { [weak self] in
                    self?.withLock {
                        guard self?.entries[path]?.generation == generation,
                              self?.entries[path]?.progress === progress else { return }
                        self?.entries[path]?.progress = nil
                    }
                }
            }
            let retained = withLock {
                guard entries[path]?.generation == generation else { return false }
                entries[path]?.token = token
                return true
            }
            if !retained { Progress.removeSubscriber(token) }
        }
    }

    func progressByPath() -> [String: FileProgress] {
        withLock { entries.compactMapValues { $0.progress.flatMap(FileProgress.read) } }
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
