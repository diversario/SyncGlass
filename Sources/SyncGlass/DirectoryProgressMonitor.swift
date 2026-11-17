import Foundation

/// Raw publication discovery; metadata, not Progress, determines transfer direction.
/// Call all methods and read counts on the supplied serial queue.
final class DirectoryProgressMonitor: @unchecked Sendable {
    typealias PublishingHandler = (Progress) -> (() -> Void)?
    typealias Subscribe = (URL, @escaping PublishingHandler) -> Any
    typealias Unsubscribe = (Any) -> Void

    private final class Directory {
        let path: String
        var token: Any?
        var operations: [ObjectIdentifier: Operation] = [:]

        init(path: String) { self.path = path }
    }

    private final class Operation {
        let path: String
        let progress: Progress
        var completedObservation: NSKeyValueObservation?
        var totalObservation: NSKeyValueObservation?
        var cancellationObservation: NSKeyValueObservation?

        init(path: String, progress: Progress) {
            self.path = path
            self.progress = progress
        }

        func invalidate() {
            completedObservation?.invalidate()
            totalObservation?.invalidate()
            cancellationObservation?.invalidate()
            completedObservation = nil
            totalObservation = nil
            cancellationObservation = nil
        }
    }

    private let queue: DispatchQueue
    private let changed: (String, Bool) -> Void
    private let subscribe: Subscribe
    private let unsubscribe: Unsubscribe
    private var directories: [String: Directory] = [:]
    private var publications: [String: Int] = [:]

    init(queue: DispatchQueue, changed: @escaping (String, Bool) -> Void,
         subscribe: @escaping Subscribe = {
             Progress.addSubscriber(forFileURL: $0, withPublishingHandler: $1)
         },
         unsubscribe: @escaping Unsubscribe = Progress.removeSubscriber) {
        self.queue = queue
        self.changed = changed
        self.subscribe = subscribe
        self.unsubscribe = unsubscribe
    }

    deinit {
        // Do not notify an owner that may itself be tearing down.
        for directory in directories.values {
            for operation in directory.operations.values { operation.invalidate() }
            if let token = directory.token { unsubscribe(token) }
        }
    }

    var directoryCount: Int { directories.count }
    var publicationCount: Int { publications.count }

    func containsDirectory(_ path: String) -> Bool { directories[path] != nil }

    func watch(_ directory: URL) {
        let url = directory.standardizedFileURL
        let path = url.path
        guard directories[path] == nil else { return }
        let entry = Directory(path: path)
        directories[path] = entry
        let queue = queue
        entry.token = subscribe(url) { [weak self, weak entry] progress in
            guard let entry, progress.kind == .file,
                  let fileURL = progress.userInfo[.fileURLKey] as? URL,
                  fileURL.isFileURL else { return nil }
            // A publication has its own identity even if Foundation reuses a Progress.
            let operation = Operation(path: fileURL.standardizedFileURL.path, progress: progress)
            queue.async { [weak self, weak entry] in
                guard let self, let entry else { return }
                self.published(operation, in: entry)
            }
            return { [weak self, weak entry, weak operation] in
                queue.async { [weak self, weak entry, weak operation] in
                    guard let self, let entry, let operation else { return }
                    self.unpublished(operation, in: entry)
                }
            }
        }
    }

    func removeSubtree(_ path: String) {
        let prefix = path == "/" ? "/" : path + "/"
        let removed = directories.keys.filter { $0 == path || $0.hasPrefix(prefix) }
        for path in removed { removeDirectory(path) }
    }

    /// Reconciliation leaves retained subscriber tokens and live operations untouched.
    func retainDirectories(_ paths: Set<String>) {
        let removed = directories.keys.filter { !paths.contains($0) }
        for path in removed { removeDirectory(path) }
    }

    func stop() {
        let removed = Array(directories.keys)
        for path in removed { removeDirectory(path) }
    }

    private func published(_ operation: Operation, in directory: Directory) {
        guard directories[directory.path] === directory else { return }
        directory.operations[ObjectIdentifier(operation)] = operation
        publications[operation.path, default: 0] += 1
        let progress = operation.progress
        let queue = queue
        let moved: () -> Void = { [weak self, weak directory, weak operation] in
            queue.async { [weak self, weak directory, weak operation] in
                guard let self, let directory, let operation,
                      self.isLive(operation, in: directory) else { return }
                self.changed(operation.path, true)
            }
        }
        operation.completedObservation = progress.observe(\.completedUnitCount, options: [.old, .new]) { _, change in
            if change.oldValue != change.newValue { moved() }
        }
        operation.totalObservation = progress.observe(\.totalUnitCount, options: [.old, .new]) { _, change in
            if change.oldValue != change.newValue { moved() }
        }
        operation.cancellationObservation = progress.observe(\.isCancelled, options: [.new]) { _, change in
            if change.newValue == true { moved() }
        }
        changed(operation.path, true)
    }

    private func isLive(_ operation: Operation, in directory: Directory) -> Bool {
        directories[directory.path] === directory &&
            directory.operations[ObjectIdentifier(operation)] === operation
    }

    private func unpublished(_ operation: Operation, in directory: Directory) {
        guard isLive(operation, in: directory) else { return }
        directory.operations.removeValue(forKey: ObjectIdentifier(operation))
        operation.invalidate()
        releasePublication(operation.path)
    }

    private func releasePublication(_ path: String) {
        guard let count = publications[path] else { return }
        if count > 1 {
            publications[path] = count - 1
        } else {
            publications.removeValue(forKey: path)
            changed(path, false)
        }
    }

    private func removeDirectory(_ path: String) {
        guard let directory = directories.removeValue(forKey: path) else { return }
        for operation in directory.operations.values {
            operation.invalidate()
            releasePublication(operation.path)
        }
        directory.operations.removeAll()
        if let token = directory.token {
            directory.token = nil
            unsubscribe(token)
        }
    }
}
