import Foundation

/// Directory-only walks register progress before the slower iCloud metadata scan.
/// The tracker queue owns this object and its progress registry.
final class DirectoryDiscovery: @unchecked Sendable {
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
    ]
    private static let prefetchKeys = Array(keys)
    private let queue: DispatchQueue
    private let monitor: DirectoryProgressMonitor
    private let completed: (String?) -> Void
    private let failed: (String) -> Void
    private var roots: [String] = []
    private var ignoreHidden = true
    private var running = false
    private var generation: UInt64 = 0
    private var pending: [String] = []
    private var pendingSet = Set<String>()
    private var pendingIndex = 0
    private var enumerator: FileManager.DirectoryEnumerator?
    private var fullScan = false
    private var seen = Set<String>()
    private var firstError: String?
    private var scheduled = false

    init(queue: DispatchQueue, monitor: DirectoryProgressMonitor,
         completed: @escaping (String?) -> Void, failed: @escaping (String) -> Void) {
        self.queue = queue
        self.monitor = monitor
        self.completed = completed
        self.failed = failed
    }

    func scan(roots: [String], ignoreHidden: Bool) {
        generation &+= 1
        enumerator = nil
        scheduled = false
        pending.removeAll(keepingCapacity: true)
        pendingSet.removeAll(keepingCapacity: true)
        pendingIndex = 0
        seen.removeAll(keepingCapacity: true)
        firstError = nil
        if self.roots != roots || self.ignoreHidden != ignoreHidden { monitor.stop() }
        self.roots = roots
        self.ignoreHidden = ignoreHidden
        running = true
        fullScan = true
        for root in roots { enqueue(root) }
        scheduleChunk()
    }

    func changed(_ path: String, isDirectory: Bool, replaced: Bool) {
        guard running, contains(path) else { return }
        if isDirectory && replaced { monitor.removeSubtree(path) }
        let directory = isDirectory ? path : (path as NSString).deletingLastPathComponent
        guard contains(directory), !monitor.containsDirectory(directory) else { return }
        var firstUnknown = directory
        var parent = (directory as NSString).deletingLastPathComponent
        while contains(parent), !monitor.containsDirectory(parent) {
            firstUnknown = parent
            let ancestor = (parent as NSString).deletingLastPathComponent
            if ancestor == parent { break }
            parent = ancestor
        }
        enqueue(firstUnknown)
    }

    func stop() {
        running = false
        generation &+= 1
        scheduled = false
        enumerator = nil
        pending.removeAll()
        pendingSet.removeAll()
        seen.removeAll()
        monitor.stop()
    }

    private func contains(_ path: String) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }

    private func enqueue(_ path: String) {
        var ancestor = path
        while contains(ancestor) {
            if pendingSet.contains(ancestor) { return }
            let parent = (ancestor as NSString).deletingLastPathComponent
            if parent == ancestor { break }
            ancestor = parent
        }
        pending.append(path)
        pendingSet.insert(path)
        scheduleChunk()
    }

    private func scheduleChunk() {
        guard running, !scheduled else { return }
        scheduled = true
        let token = generation
        queue.async { [weak self] in
            guard let self, self.running, self.generation == token else { return }
            self.scheduled = false
            self.walkChunk()
        }
    }

    private func record(_ url: URL, error: Error) {
        // A folder can disappear between a file event and its directory walk.
        let nsError = error as NSError
        if !roots.contains(url.path),
           (nsError.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code)) ||
            (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)) { return }
        record("Cannot watch \(url.path): \(error.localizedDescription)")
    }

    private func record(_ message: String) {
        if fullScan {
            if firstError == nil { firstError = message }
        } else {
            failed(message)
        }
    }

    private func register(_ url: URL) {
        monitor.watch(URL(fileURLWithPath: url.path, isDirectory: true))
        if fullScan { seen.insert(url.path) }
    }

    private func walkChunk() {
        var inspected = 0
        while inspected < 512 {
            if enumerator == nil {
                guard pendingIndex < pending.count else {
                    pending.removeAll(keepingCapacity: true)
                    pendingIndex = 0
                    if fullScan {
                        fullScan = false
                        if firstError == nil { monitor.retainDirectories(seen) }
                        seen.removeAll()
                        completed(firstError)
                    }
                    return
                }
                let path = pending[pendingIndex]
                pendingIndex += 1
                pendingSet.remove(path)
                inspected += 1
                let url = URL(fileURLWithPath: path, isDirectory: true)
                do {
                    let values = try url.resourceValues(forKeys: Self.keys)
                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                        if roots.contains(path) { record("Watched path is not a regular folder: \(path)") }
                        continue
                    }
                    // Explicit watched roots remain usable even when their name is hidden.
                    guard !ignoreHidden || values.isHidden != true || roots.contains(path) else { continue }
                    register(url)
                    if values.isPackage == true { continue }
                    var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
                    if ignoreHidden { options.insert(.skipsHiddenFiles) }
                    enumerator = FileManager.default.enumerator(at: url,
                        includingPropertiesForKeys: Self.prefetchKeys, options: options,
                        errorHandler: { [weak self] url, error in
                            self?.record(url, error: error)
                            return true
                        })
                    if enumerator == nil {
                        record("Cannot enumerate watched folder: \(path)")
                    }
                } catch { record(url, error: error) }
                continue
            }
            guard let url = enumerator?.nextObject() as? URL else {
                enumerator = nil
                continue
            }
            inspected += 1
            do {
                let values = try url.resourceValues(forKeys: Self.keys)
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      values.isPackage != true else { continue }
                register(url)
            } catch { record(url, error: error) }
        }
        scheduleChunk()
    }
}
