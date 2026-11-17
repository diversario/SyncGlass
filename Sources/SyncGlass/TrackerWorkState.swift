import Foundation

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
    private var publishedPaths = Set<String>()
    private var priority: [String] = []
    private var prioritySet = Set<String>()
    private var priorityIndex = 0
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
        pending.removeAll()
        pendingSet.removeAll()
        pendingIndex = 0
        publishedPaths.removeAll()
        priority.removeAll()
        prioritySet.removeAll()
        priorityIndex = 0
        recheckOrder.removeAll()
        recheckIndex = 0
        orderDirty = true
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
        priority = priority[priorityIndex...].filter { prioritySet.contains($0) && contains($0) }
        prioritySet = Set(priority)
        priorityIndex = 0
        publishedPaths = publishedPaths.filter(contains)
        for path in Array(items.keys) where !contains(path) { items.removeValue(forKey: path) }
        for path in Array(failures.keys) where !contains(path) { failures.removeValue(forKey: path) }
        restoredPaths = restoredPaths.filter(contains)
        membershipDirty = true
        orderDirty = true
        snapshotDirty = true
        persistenceDirty = true
        publish()
        enqueue(Array(items.keys) + Array(failures.keys) + Array(restoredPaths) + Array(publishedPaths))
        if pendingSet.isEmpty, !prioritySet.isEmpty { wake() }
    }

    func enqueue(_ paths: [String]) {
        guard running else { return }
        for path in paths where pendingSet.insert(path).inserted { pending.append(path) }
        if !paths.isEmpty { wake() }
    }

    /// Publication only requests metadata; it never supplies transfer direction.
    func progressChanged(_ path: String, published: Bool) {
        guard running else { return }
        if published {
            if publishedPaths.insert(path).inserted { orderDirty = true }
        } else if publishedPaths.remove(path) != nil {
            orderDirty = true
        }
        if prioritySet.insert(path).inserted { priority.append(path) }
        wake()
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
            prioritySet.remove(path)
            publishedPaths.remove(path)
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
    private var hasWork: Bool {
        !prioritySet.isEmpty || !pendingSet.isEmpty || !publishedPaths.isEmpty || !items.isEmpty || !failures.isEmpty
    }

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
        while checked.count < limit && priorityIndex < priority.count {
            let path = priority[priorityIndex]
            priorityIndex += 1
            guard prioritySet.remove(path) != nil, checked.insert(path).inserted else { continue }
            pendingSet.remove(path)
            apply(path, state: read(path))
        }
        if priorityIndex == priority.count {
            priority.removeAll(keepingCapacity: true)
            priorityIndex = 0
        }
        while checked.count < limit && pendingIndex < pending.count {
            let path = pending[pendingIndex]
            pendingIndex += 1
            guard pendingSet.remove(path) != nil, checked.insert(path).inserted else { continue }
            apply(path, state: read(path))
        }
        if pendingIndex == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingIndex = 0
        }
        if orderDirty {
            let nextPath = recheckOrder.isEmpty ? nil : recheckOrder[recheckIndex % recheckOrder.count]
            recheckOrder = Array(Set(items.keys).union(failures.keys).union(publishedPaths)).sorted()
            // Keep the round-robin cursor when candidate membership changes.
            recheckIndex = nextPath.flatMap { next in recheckOrder.firstIndex { $0 >= next } } ?? 0
            orderDirty = false
        }
        // A path is read at most once per pass, including newly discovered work.
        var visited = 0
        while checked.count < limit && visited < recheckOrder.count {
            if recheckIndex >= recheckOrder.count { recheckIndex = 0 }
            let path = recheckOrder[recheckIndex]
            recheckIndex += 1
            visited += 1
            guard !checked.contains(path),
                  items[path] != nil || failures[path] != nil || publishedPaths.contains(path) else { continue }
            checked.insert(path)
            apply(path, state: read(path))
        }
        publish()
        guard canWork, hasWork else { return }
        if !prioritySet.isEmpty || !pendingSet.isEmpty {
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
