import AppKit
import Observation

/// Shared state for the status item and its panel.
@MainActor
@Observable
final class StatusModel {
    private(set) var snapshot = TrackerSnapshot()
    private(set) var isReachable = true
    private(set) var uploads = DirectionSummary(items: [], direction: .upload, progress: [:])
    private(set) var downloads = DirectionSummary(items: [], direction: .download, progress: [:])
    private(set) var fileProgress: [String: FileProgress] = [:]
    private(set) var panelIsOpen = false
    var isPreview = false

    @ObservationIgnored let fileProgressMonitor = FileProgressMonitor()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var visibleUploads = Set<String>()
    @ObservationIgnored private var visibleDownloads = Set<String>()
    @ObservationIgnored private var conflicts = Set<String>()
    @ObservationIgnored private var itemsByPath: [String: TransferItem] = [:]

    func update(_ snapshot: TrackerSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        itemsByPath = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.path, $0) })
        fileProgress = fileProgress.filter { itemsByPath[$0.key] != nil }
        uploads = DirectionSummary(items: snapshot.items, direction: .upload, progress: fileProgress)
        downloads = DirectionSummary(items: snapshot.items, direction: .download, progress: fileProgress)
        reconcileProgress()
        onChange?()
    }

    func setReachable(_ reachable: Bool) {
        guard isReachable != reachable else { return }
        isReachable = reachable
        onChange?()
    }

    func summary(for direction: TransferDirection) -> DirectionSummary {
        direction == .upload ? uploads : downloads
    }

    func progress(for path: String, direction: TransferDirection) -> FileProgress? {
        guard let progress = fileProgress[path],
              let item = itemsByPath[path],
              progress.matches(item, direction: direction) else { return nil }
        return progress
    }

    func openPanel() {
        guard !panelIsOpen else { return }
        panelIsOpen = true
        if !isPreview, let tracker = Tracker.shared { update(tracker.snapshot()) }
        reconcileProgress()
    }

    func closePanel() {
        panelIsOpen = false
        progressTask?.cancel()
        progressTask = nil
        fileProgressMonitor.track([String]())
        visibleUploads.removeAll()
        visibleDownloads.removeAll()
        conflicts.removeAll()
        if !isPreview {
            fileProgress.removeAll()
            updateByteSummaries()
        }
    }

    func setVisible(_ path: String, direction: TransferDirection, visible: Bool) {
        let changed: Bool
        if direction == .upload {
            changed = visible ? visibleUploads.insert(path).inserted : visibleUploads.remove(path) != nil
        } else {
            changed = visible ? visibleDownloads.insert(path).inserted : visibleDownloads.remove(path) != nil
        }
        if changed { updateSubscriptions() }
    }

    func setPreviewProgress(_ progress: [String: FileProgress]) {
        guard isPreview else { return }
        fileProgress = progress
        updateByteSummaries()
    }

    private func reconcileProgress() {
        guard panelIsOpen, !isPreview else { return }
        updateSubscriptions()
        if snapshot.items.isEmpty {
            progressTask?.cancel()
            progressTask = nil
            return
        }
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshProgress()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    private func updateSubscriptions() {
        guard panelIsOpen, !isPreview else { return }
        let visible = visibleUploads.union(visibleDownloads)
        let priority = snapshot.items.filter { visible.contains($0.path) }.map(\.path)
        let remaining = snapshot.items.filter { !visible.contains($0.path) }.map(\.path)
        fileProgressMonitor.track(priority + remaining)
    }

    private func refreshProgress() {
        let latest = fileProgressMonitor.progressByPath()
        var mismatched = Set<String>()
        for item in snapshot.items {
            guard let direction = latest[item.path]?.direction else { continue }
            let flag: TransferDirections = direction == .uploading ? .upload : .download
            if !item.active.contains(flag) { mismatched.insert(item.path) }
        }
        let fresh = mismatched.subtracting(conflicts)
        conflicts = mismatched
        if !fresh.isEmpty { Tracker.shared?.queuePaths(Array(fresh)) }
        guard latest != fileProgress else { return }
        fileProgress = latest
        updateByteSummaries()
    }

    private func updateByteSummaries() {
        uploads.updateProgress(direction: .upload, progress: fileProgress)
        downloads.updateProgress(direction: .download, progress: fileProgress)
    }

    var isWatchingForStuckFiles: Bool { ICloudQueueMonitor.shared.isWatching }
    var stuckCount: Int { ICloudQueueMonitor.shared.stuck.count }
    var lastStuckFileCheck: Date? { ICloudQueueMonitor.shared.lastCheck }
    func isStuck(_ path: String) -> Bool { ICloudQueueMonitor.shared.stuck.contains(path) }
    func transferError(for path: String) -> String? {
        itemsByPath[path]?.error ?? ICloudQueueMonitor.shared.errors[path]
    }

    func toggleStuckFileWatch() {
        guard !isPreview else { return }
        let monitor = ICloudQueueMonitor.shared
        if monitor.isWatching { monitor.stop() } else { monitor.start(progress: fileProgressMonitor) }
        onChange?()
    }

    func reveal(_ path: String) {
        guard !isPreview else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
