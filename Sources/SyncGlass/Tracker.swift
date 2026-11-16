import CoreServices
import Foundation

@MainActor
protocol TrackerDelegate: AnyObject {
    func trackerStatusChanged(_ snapshot: TrackerSnapshot)
}

/// Deterministic scheduling and metadata state. Its owner serializes every call.
/// The scheduler returns a cancellation closure; generations also reject callbacks
/// that were already enqueued when cancellation happened.
final class TrackerWorkState {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> (() -> Void)

    var batchSize = 25
    var trackDownloads = true
    var accepts: (String, ItemState) -> Bool = { _, _ in true }
    var onSnapshot: (TrackerSnapshot) -> Void = { _ in }
    var persist: (Set<String>) -> Void = { _ in }
    private let read: (String) -> ItemState
    private let schedule: Scheduler
    private var items: [String: TransferItem] = [:]
    private var failures: [String: String] = [:]
    private var pending: [String] = []
    private var pendingSet = Set<String>()
    private var pendingIndex = 0
    private var recheckOrder: [String] = []
    private var recheckIndex = 0
    private var orderDirty = false
    private var sortedPaths: [String] = []
    private var membershipDirty = false
    private var savedPaths = Set<String>()
    private var restoredPaths = Set<String>()
    private var snapshotDirty = false
    private var persistenceDirty = false
    private var scheduledDelay: TimeInterval?
    private var cancellation: (() -> Void)?
    private var generation: UInt64 = 0
    private var backoff = 0
    private var running = false
    private var paused = false
    private var reachable = true
    private var monitorAvailability: MonitorAvailability = .ready
    private var scanning = false
    private(set) var snapshot = TrackerSnapshot()

    init(read: @escaping (String) -> ItemState, schedule: @escaping Scheduler) {
        self.read = read
        self.schedule = schedule
    }

    func start(paths: [String] = [], keeping contains: (String) -> Bool = { _ in true }) {
        running = true
        savedPaths = Set(paths)
        restoredPaths = Set(paths.filter(contains))
        persistenceDirty = true
        enqueue(Array(restoredPaths.union(items.keys).union(failures.keys)).sorted())
        publish()
    }

    func stop() {
        running = false
        cancelPass()
    }

    func pause() {
        paused = true
        cancelPass()
    }

    func resume() {
        paused = false
        wake()
    }

    func setReachable(_ value: Bool) {
        reachable = value
        if value { wake() } else { cancelPass() }
    }

    /// A new watched scope discards all obsolete pending and scheduled work.
    func replaceScope(keeping contains: (String) -> Bool) {
        cancelPass()
        pending.removeAll()
        pendingSet.removeAll()
        pendingIndex = 0
        for path in Array(items.keys) where !contains(path) { items.removeValue(forKey: path) }
        for path in Array(failures.keys) where !contains(path) { failures.removeValue(forKey: path) }
        restoredPaths = restoredPaths.filter(contains)
        membershipDirty = true
        orderDirty = true
        snapshotDirty = true
        persistenceDirty = true
        publish()
        enqueue(Array(items.keys) + Array(failures.keys) + Array(restoredPaths))
    }

    func enqueue(_ paths: [String]) {
        guard running else { return }
        for path in paths where pendingSet.insert(path).inserted { pending.append(path) }
        if !paths.isEmpty { wake() }
    }

    /// Scanning supplies already-read metadata, retaining only candidates/errors.
    func ingest(_ candidates: [(String, ItemState)]) {
        guard running, !candidates.isEmpty else { return }
        let previous = snapshot
        for (path, state) in candidates { apply(path, state: state) }
        publish()
        if previous != snapshot { wake(immediate: false) }
    }

    func remove(_ paths: [String]) {
        for path in paths {
            items.removeValue(forKey: path)
            failures.removeValue(forKey: path)
            pendingSet.remove(path)
            restoredPaths.remove(path)
        }
        membershipDirty = true
        orderDirty = true
        snapshotDirty = true
        persistenceDirty = true
        publish()
        wake(immediate: false)
    }

    func setMonitor(availability: MonitorAvailability, scanning: Bool) {
        if monitorAvailability != availability || self.scanning != scanning { snapshotDirty = true }
        monitorAvailability = availability
        self.scanning = scanning
        publish()
    }

    func preferencesChanged() {
        enqueue(Array(items.keys) + Array(failures.keys))
    }

    private var canWork: Bool { running && !paused && reachable }
    private var hasWork: Bool { !pendingSet.isEmpty || !items.isEmpty || !failures.isEmpty }

    private func cancelPass() {
        generation &+= 1
        cancellation?()
        cancellation = nil
        scheduledDelay = nil
    }

    private func wake(immediate: Bool = true) {
        backoff = 0
        // Streaming discovery must not keep pushing an already-near pass out.
        if !immediate, canWork, hasWork, let scheduledDelay, scheduledDelay <= 1 { return }
        cancelPass()
        guard canWork, hasWork else { return }
        schedulePass(after: immediate ? 0 : 1)
    }

    private func schedulePass(after delay: TimeInterval) {
        guard cancellation == nil, canWork, hasWork else { return }
        let token = generation
        scheduledDelay = delay
        cancellation = schedule(delay) { [weak self] in
            guard let self, self.generation == token, self.canWork else { return }
            self.cancellation = nil
            self.scheduledDelay = nil
            self.pass()
        }
    }

    private func pass() {
        let previous = snapshot
        var checked = Set<String>()
        let limit = max(1, batchSize)
        while checked.count < limit && pendingIndex < pending.count {
            let path = pending[pendingIndex]
            pendingIndex += 1
            guard pendingSet.remove(path) != nil else { continue }
            checked.insert(path)
            apply(path, state: read(path))
        }
        if pendingIndex == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingIndex = 0
        }
        if orderDirty {
            recheckOrder = Array(Set(items.keys).union(failures.keys)).sorted()
            recheckIndex = 0
            orderDirty = false
        }
        // A path is read at most once per pass, including newly discovered work.
        var visited = 0
        while checked.count < limit && visited < recheckOrder.count {
            if recheckIndex >= recheckOrder.count { recheckIndex = 0 }
            let path = recheckOrder[recheckIndex]
            recheckIndex += 1
            visited += 1
            guard !checked.contains(path), items[path] != nil || failures[path] != nil else { continue }
            checked.insert(path)
            apply(path, state: read(path))
        }
        publish()
        guard canWork, hasWork else { return }
        if !pendingSet.isEmpty {
            schedulePass(after: 0)
        } else {
            let delays: [TimeInterval] = [1, 2, 5, 10]
            if previous != snapshot { backoff = 0 }
            let delay = delays[backoff]
            backoff = min(backoff + 1, delays.count - 1)
            schedulePass(after: delay)
        }
    }

    private func apply(_ path: String, state: ItemState) {
        let old = items[path]
        if restoredPaths.remove(path) != nil { persistenceDirty = true }
        let hadFailure = failures[path] != nil
        let previousFailure = failures[path]
        switch state.phase(trackDownloads: trackDownloads) {
        case .unavailable(let message):
            failures[path] = message
            if var item = old {
                item.error = message
                items[path] = item
            }
        case .inFlight(let active, let waiting):
            failures.removeValue(forKey: path)
            // Discovery filters do not turn an existing transfer into completion.
            if old != nil || accepts(path, state) {
                items[path] = TransferItem(path: path, active: active, waitingUpload: waiting, error: state.transferError)
            } else {
                items.removeValue(forKey: path)
            }
        case .ignored, .current:
            failures.removeValue(forKey: path)
            items.removeValue(forKey: path)
        }
        let membershipChanged = (old == nil) != (items[path] == nil)
        if old != items[path] || previousFailure != failures[path] { snapshotDirty = true }
        if membershipChanged { membershipDirty = true }
        if membershipChanged || hadFailure != (failures[path] != nil) {
            orderDirty = true
            persistenceDirty = true
        }
    }

    private func publish() {
        if persistenceDirty {
            persistenceDirty = false
            let paths = Set(items.keys).union(failures.keys).union(restoredPaths)
            if paths != savedPaths {
                savedPaths = paths
                persist(paths)
            }
        }
        guard snapshotDirty else { return }
        snapshotDirty = false
        if membershipDirty {
            sortedPaths = items.keys.sorted()
            membershipDirty = false
        }
        let availability: MonitorAvailability
        if case .unavailable = monitorAvailability {
            availability = monitorAvailability
        } else if let path = failures.keys.min(), let error = failures[path] {
            availability = .unavailable("Cannot read metadata for \(path): \(error)")
        } else {
            availability = .ready
        }
        let next = TrackerSnapshot(items: sortedPaths.compactMap { items[$0] },
                                   availability: availability, isScanning: scanning)
        if next != snapshot {
            snapshot = next
            onSnapshot(next)
        }
    }
}

/// FSEvents, discovery, metadata reads, and scheduling all share one utility queue.
final class Tracker: @unchecked Sendable {
    nonisolated(unsafe) private(set) static var shared: Tracker?
    @MainActor weak var delegate: TrackerDelegate?

    private let queue: DispatchQueue
    private let snapshotLock = NSLock()
    private var publishedSnapshot = TrackerSnapshot(
        availability: .unavailable("Starting file monitor…"), isScanning: true)
    private var acceptsSnapshots = true
    private var directory: String
    private var roots: [String] = []
    private var running = false
    private var stream: FSEventStreamRef?
    private var presenters: [DirectoryPresenter] = []
    private lazy var presenterDispatchQueue = DispatchQueue(label: "SyncGlass.file-presenter",
        qos: .utility, autoreleaseFrequency: .workItem)
    private lazy var presenterQueue: OperationQueue = {
        let operations = OperationQueue()
        operations.name = "SyncGlass.file-presenters"
        operations.maxConcurrentOperationCount = 1
        operations.qualityOfService = .utility
        operations.underlyingQueue = presenterDispatchQueue
        return operations
    }()
    private var streamGeneration: UInt64 = 0
    private var scanGeneration: UInt64 = 0
    private var scan: FileManager.DirectoryEnumerator?
    private var scanRootIndex = 0
    private var scanErrors: [String] = []
    private var streamError: String?
    private var lastEventID: FSEventStreamEventId = 0
    private var savedEventID: FSEventStreamEventId = 0

    private lazy var work: TrackerWorkState = {
        let state = TrackerWorkState(read: { ItemState(url: URL(fileURLWithPath: $0)) }, schedule: { [weak self] delay, body in
            guard let self else { return {} }
            let item = DispatchWorkItem(block: body)
            self.queue.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        })
        state.persist = { InFlightTransfersStore.save($0) }
        state.accepts = { path, metadata in
            Self.acceptsTransfer(path, metadata: metadata, ignoreHidden: Prefs.ignoreHiddenFiles,
                                 ignoreSymlinks: Prefs.ignoreSymbolicLinks,
                                 trackDownloads: Prefs.trackIncomingDownloads,
                                 includes: Prefs.includePatterns, excludes: Prefs.excludePatterns)
        }
        state.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.snapshotLock.lock()
            let accepted = self.acceptsSnapshots
            if accepted { self.publishedSnapshot = snapshot }
            self.snapshotLock.unlock()
            guard accepted else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentSnapshot(snapshot) else { return }
                MainActor.assumeIsolated { self.delegate?.trackerStatusChanged(snapshot) }
            }
        }
        return state
    }()

    init(directory: String, queue: DispatchQueue = DispatchQueue(
        label: "SyncGlass.tracker", qos: .utility, autoreleaseFrequency: .workItem)) {
        self.queue = queue
        self.directory = Self.normalized(directory)
        Tracker.shared = self
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.snapshotLock.lock()
            self.acceptsSnapshots = true
            self.snapshotLock.unlock()
            self.running = true
            self.configurePreferences()
            self.roots = self.watchedRoots()
            self.work.replaceScope(keeping: self.isInScope)
            self.startStream()
            self.work.start(paths: InFlightTransfersStore.load(), keeping: self.isInScope)
            self.beginScan()
        }
    }

    func stop() {
        snapshotLock.lock()
        acceptsSnapshots = false
        publishedSnapshot = TrackerSnapshot(availability: .unavailable("Monitoring stopped"))
        snapshotLock.unlock()
        queue.async { [self] in
            running = false
            work.stop()
            scanGeneration &+= 1
            scan = nil
            stopStream()
            saveLastEventID()
        }
    }

    func setDirectory(_ path: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.directory = Self.normalized(path)
            guard self.running else { return }
            self.scanGeneration &+= 1
            self.scan = nil
            self.roots = self.watchedRoots()
            self.work.setMonitor(availability: .unavailable("Watched folders changed; scanning…"), scanning: true)
            self.work.replaceScope(keeping: self.isInScope)
            self.startStream()
            self.beginScan()
        }
    }

    /// Reading the UI snapshot never waits for a filesystem or permission request.
    func snapshot() -> TrackerSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return publishedSnapshot
    }

    private func isCurrentSnapshot(_ snapshot: TrackerSnapshot) -> Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return acceptsSnapshots && publishedSnapshot == snapshot
    }
    func pause() { queue.async { [weak self] in self?.work.pause() } }
    func resume() { queue.async { [weak self] in self?.work.resume() } }
    func networkReachabilityChanged(isReachable: Bool) {
        queue.async { [weak self] in self?.work.setReachable(isReachable) }
    }
    func queuePaths(_ paths: [String]) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.work.enqueue(paths.map(Self.normalized).filter(self.isInScope))
        }
    }
    func requestScan() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.beginScan()
        }
    }
    func removeTransfers(_ paths: [String]) {
        queue.async { [weak self] in self?.work.remove(paths) }
    }
    func saveEventID() { queue.sync { saveLastEventID() } }
    func preferencesChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            self.configurePreferences()
            self.work.preferencesChanged()
        }
    }

    static func acceptsTransfer(_ path: String, metadata: ItemState, ignoreHidden: Bool,
                                ignoreSymlinks: Bool, trackDownloads: Bool,
                                includes: [String], excludes: [String]) -> Bool {
        guard !path.hasSuffix(".DS_Store"),
              !(ignoreHidden && metadata.isHidden && !(trackDownloads && metadata.isDownloading)),
              !(ignoreSymlinks && metadata.isSymbolicLink),
              !metadata.isDirectory || metadata.isPackage,
              PathChecks.passesFilters(path, includes: includes, excludes: excludes),
              !PathChecks.isInsideImplicitPackage(path) else { return false }
        return !PathChecks.isInsidePackage(path)
    }

    static func startEventID(saved: UInt64?, current: UInt64) -> FSEventStreamEventId {
        guard let saved, saved > 0, saved <= current else {
            return FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        }
        return saved
    }

    static func deduplicatedRoots(_ paths: [String]) -> [String] {
        let sorted = Set(paths.map(normalized)).sorted {
            $0.count == $1.count ? $0 < $1 : $0.count < $1.count
        }
        return sorted.reduce(into: [String]()) { roots, path in
            if !roots.contains(where: { contains(path, in: $0) }) { roots.append(path) }
        }
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }
    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    private func isInScope(_ path: String) -> Bool { roots.contains { Self.contains(path, in: $0) } }
    private func watchedRoots() -> [String] {
        var paths = [directory]
        for folder in [FileManager.SearchPathDirectory.documentDirectory, .desktopDirectory] {
            if let path = NSSearchPathForDirectoriesInDomains(folder, .userDomainMask, true).last,
               PathChecks.isTracked(path) { paths.append(path) }
        }
        return Self.deduplicatedRoots(paths)
    }
    private func configurePreferences() {
        work.batchSize = Prefs.pollingMode.batchSize
        work.trackDownloads = Prefs.trackIncomingDownloads
    }

    private func stopStream() {
        streamGeneration &+= 1
        for presenter in presenters { NSFileCoordinator.removeFilePresenter(presenter) }
        presenters.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func startStream() {
        stopStream()
        streamError = nil
        let generation = streamGeneration
        presenters = roots.map { root in
            let presenter = DirectoryPresenter(directory: URL(fileURLWithPath: root, isDirectory: true),
                                                queue: presenterQueue) { [weak self] url in
                let path = Self.normalized(url.path)
                self?.queue.async { [weak self] in
                    guard let self, self.running, self.streamGeneration == generation,
                          self.isInScope(path) else { return }
                    self.work.enqueue([path])
                }
            }
            NSFileCoordinator.addFilePresenter(presenter)
            return presenter
        }
        let contextObject = TrackerStreamContext(tracker: self, generation: streamGeneration)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(contextObject).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<TrackerStreamContext>.fromOpaque(info).retain()
                return info
            }, release: { info in
                if let info { Unmanaged<TrackerStreamContext>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, ids in
            guard let info else { return }
            let context = Unmanaged<TrackerStreamContext>.fromOpaque(info).takeUnretainedValue()
            guard let tracker = context.tracker, tracker.running,
                  tracker.streamGeneration == context.generation else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            for i in 0..<min(count, paths.count) { tracker.received(paths[i], flags: flags[i], id: ids[i]) }
        }
        let current = FSEventsGetCurrentEventId()
        if lastEventID > current { lastEventID = 0 }
        let saved = lastEventID == 0
            ? (Prefs.store.object(forKey: PrefKey.lastEventID) as? NSNumber)?.uint64Value : lastEventID
        let since = Self.startEventID(saved: saved, current: current)
        if lastEventID == 0 { lastEventID = since == FSEventStreamEventId(kFSEventStreamEventIdSinceNow) ? current : since }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray, since, 1, flags) else {
            streamError = "Cannot create the file monitor."
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamError = "Cannot start the file monitor."
            return
        }
        self.stream = stream
    }

    private func received(_ path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId) {
        guard running else { return }
        let wrapped = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0
        lastEventID = wrapped ? id : max(lastEventID, id)
        saveLastEventID()
        let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
        if flags & rescanFlags != 0 {
            work.setMonitor(availability: .unavailable("File events changed; rescanning watched folders…"), scanning: true)
            if wrapped || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 { startStream() }
            beginScan()
        } else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0, isInScope(path) {
            work.enqueue([path])
        }
    }

    private func saveLastEventID() {
        guard lastEventID != 0, lastEventID != savedEventID else { return }
        savedEventID = lastEventID
        Prefs.store.set(NSNumber(value: lastEventID), forKey: PrefKey.lastEventID)
    }

    private func beginScan() {
        scanGeneration &+= 1
        scan = nil
        scanRootIndex = 0
        scanErrors.removeAll()
        work.setMonitor(availability: streamError.map { .unavailable($0) } ?? work.snapshot.availability, scanning: true)
        let token = scanGeneration
        queue.async { [weak self] in self?.scanChunk(generation: token) }
    }

    /// No contents, downloads, size aggregation, or full-tree inventory.
    private func scanChunk(generation: UInt64) {
        guard running, generation == scanGeneration else { return }
        var inspected = 0
        var candidates: [(String, ItemState)] = []
        let limit = max(25, work.batchSize)
        while inspected < limit {
            if scan == nil {
                guard scanRootIndex < roots.count else {
                    let error = streamError ?? scanErrors.first
                    work.ingest(candidates)
                    work.setMonitor(availability: error.map { .unavailable($0) } ?? .ready, scanning: false)
                    return
                }
                let root = roots[scanRootIndex]
                scanRootIndex += 1
                do {
                    let values = try URL(fileURLWithPath: root).resourceValues(forKeys: [.isDirectoryKey])
                    guard values.isDirectory == true, FileManager.default.isReadableFile(atPath: root) else {
                        scanErrors.append("Cannot read watched folder: \(root)")
                        continue
                    }
                } catch {
                    scanErrors.append("Cannot read \(root): \(error.localizedDescription)")
                    continue
                }
                scan = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: ItemState.prefetchKeys,
                    options: [.skipsPackageDescendants], errorHandler: { [weak self] url, error in
                        self?.scanErrors.append("Cannot read \(url.path): \(error.localizedDescription)")
                        return true
                    })
                if scan == nil { scanErrors.append("Cannot enumerate watched folder: \(root)") }
                inspected += 1
                continue
            }
            guard let url = scan?.nextObject() as? URL else {
                scan = nil
                continue
            }
            inspected += 1
            let state = ItemState(url: url)
            if (Prefs.ignoreSymbolicLinks && state.isSymbolicLink)
                || (Prefs.ignoreHiddenFiles && state.isHidden && !(Prefs.trackIncomingDownloads && state.isDownloading)) {
                if state.isDirectory { scan?.skipDescendants() }
                continue
            }
            if state.isDirectory && !state.isPackage { continue }
            switch state.phase(trackDownloads: work.trackDownloads) {
            case .inFlight, .unavailable: candidates.append((url.path, state))
            case .current, .ignored: break
            }
        }
        work.ingest(candidates)
        queue.async { [weak self] in self?.scanChunk(generation: generation) }
    }
}

private final class TrackerStreamContext {
    weak var tracker: Tracker?
    let generation: UInt64
    init(tracker: Tracker, generation: UInt64) {
        self.tracker = tracker
        self.generation = generation
    }
}
