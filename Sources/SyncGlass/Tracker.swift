import CoreServices
import Foundation

@MainActor
protocol TrackerDelegate: AnyObject {
    func trackerStatusChanged(_ snapshot: TrackerSnapshot)
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
    private lazy var progressMonitor = DirectoryProgressMonitor(queue: queue, changed: { [weak self] path, published in
        guard let self, self.running, self.isInScope(path) else { return }
        self.work.progressChanged(path, published: published)
    })
    private lazy var directoryDiscovery = DirectoryDiscovery(queue: queue, monitor: progressMonitor,
        completed: { [weak self] error in
            guard let self, self.running else { return }
            self.discoveryError = error
            let failure = self.streamError ?? error
            self.work.setMonitor(availability: failure.map { .unavailable($0) } ?? .ready, scanning: true)
            let token = self.scanGeneration
            self.queue.async { [weak self] in self?.scanChunk(generation: token) }
        }, failed: { [weak self] error in
            guard let self, self.running else { return }
            self.discoveryError = error
            self.work.setMonitor(availability: .unavailable(error), scanning: self.work.snapshot.isScanning)
        })
    private var discoveryError: String?
    private var scannedIgnoreHidden: Bool?
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
            directoryDiscovery.stop()
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
            if self.running, self.scannedIgnoreHidden != Prefs.ignoreHiddenFiles { self.beginScan() }
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
            directoryDiscovery.changed(path,
                isDirectory: flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0,
                replaced: flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved
                    | kFSEventStreamEventFlagItemRenamed) != 0)
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
        scannedIgnoreHidden = Prefs.ignoreHiddenFiles
        directoryDiscovery.scan(roots: roots, ignoreHidden: Prefs.ignoreHiddenFiles)
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
                    let error = streamError ?? discoveryError ?? scanErrors.first
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
