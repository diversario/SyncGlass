import CoreServices
import Foundation
import Testing
@testable import SyncGlass

@Suite struct StartEventIDTests {
    static let now = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

    @Test func replaysFromTheSavedID() {
        #expect(Tracker.startEventID(saved: 500, current: 900) == 500)
        #expect(Tracker.startEventID(saved: 900, current: 900) == 900)
    }

    @Test func startsNowWithoutASavedID() {
        #expect(Tracker.startEventID(saved: nil, current: 900) == Self.now)
        #expect(Tracker.startEventID(saved: 0, current: 900) == Self.now)
    }

    /// An ID newer than the current one means the event database was reset.
    @Test func startsNowAfterAReset() {
        #expect(Tracker.startEventID(saved: 901, current: 900) == Self.now)
    }
}

@Suite struct TrackerSchedulingTests {
    @Test func snapshotAndStopDoNotWaitForBlockedFilesystemWork() {
        let queue = DispatchQueue(label: "SyncGlass.test.blocked-metadata")
        let tracker = Tracker(directory: "/test", queue: queue)
        queue.suspend()
        defer { queue.resume() }
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let snapshot = tracker.snapshot()
            #expect(snapshot.isScanning)
            #expect(snapshot.availability == .unavailable("Starting file monitor…"))
            tracker.stop()
            #expect(tracker.snapshot().availability == .unavailable("Monitoring stopped"))
            completed.signal()
        }
        #expect(completed.wait(timeout: .now() + 2) == .success)
    }

    @Test func productionFilterKeepsZeroByteTransfersInListsAndCounts() {
        let h = TrackerHarness()
        h.metadata = [
            "/zero-upload": ItemState(isUploaded: false, isUploading: true, fileSize: 0),
            "/zero-download": ItemState(isDownloading: true, fileSize: 0),
            "/zero-waiting": ItemState(isUploaded: false, fileSize: 0),
        ]
        h.work.accepts = {
            Tracker.acceptsTransfer($0, metadata: $1, ignoreHidden: true, ignoreSymlinks: true,
                                    trackDownloads: true, includes: [], excludes: [])
        }
        h.work.start(paths: Array(h.metadata.keys))
        h.clock.fireNext()
        #expect(h.work.snapshot.items.map(\.path) == ["/zero-download", "/zero-upload", "/zero-waiting"])
        let up = DirectionSummary(items: h.work.snapshot.items, direction: .upload, progress: [:])
        let down = DirectionSummary(items: h.work.snapshot.items, direction: .download, progress: [:])
        #expect(up.fileCount == 2)
        #expect(down.fileCount == 1)
        #expect(up.unavailableCount == 2)
        #expect(down.unavailableCount == 1)
        #expect(up.fraction == nil)
        #expect(down.fraction == nil)
    }

    @Test func trueIdleHasNoScheduledWorkAndEventsWakeIt() {
        let h = TrackerHarness()
        h.work.start()
        #expect(h.clock.active.isEmpty)
        h.metadata["/a"] = ItemState()
        h.work.enqueue(["/a"])
        #expect(h.clock.active.map(\.delay) == [0])
        h.clock.fireNext()
        #expect(h.work.snapshot.items.isEmpty)
        #expect(h.clock.active.isEmpty)
        #expect(h.reads == ["/a"])
        h.metadata["/b"] = ItemState(isUploading: true)
        h.work.enqueue(["/b"])
        h.clock.fireNext()
        #expect(h.work.snapshot.activeDirections == .upload)
        #expect(h.clock.active.map(\.delay) == [1])
    }

    @Test func unchangedWorkBacksOffAndNewEventsResetIt() {
        let h = TrackerHarness()
        h.metadata["/a"] = ItemState(isUploading: true)
        h.work.start(paths: ["/a"])
        h.clock.fireNext()
        for delay in [1.0, 2, 5, 10, 10] {
            #expect(h.clock.active.map(\.delay) == [delay])
            h.clock.fireNext()
        }
        #expect(h.emissions.count == 1)
        h.work.enqueue(["/a"])
        #expect(h.clock.active.map(\.delay) == [0])
        h.clock.fireNext()
        #expect(h.clock.active.map(\.delay) == [1])
    }

    @Test func directionChangesPublishEvenWithTheSameCount() {
        let h = TrackerHarness()
        h.metadata["/a"] = ItemState(isUploading: true)
        h.work.start(paths: ["/a"])
        h.clock.fireNext()
        h.metadata["/a"] = ItemState(isDownloading: true)
        h.clock.fireNext()
        #expect(h.work.snapshot.items.count == 1)
        #expect(h.work.snapshot.activeDirections == .download)
        #expect(h.emissions.count == 2)
        h.metadata["/a"] = ItemState(isUploading: true, isDownloading: true)
        h.clock.fireNext()
        #expect(h.work.snapshot.activeDirections == [.upload, .download])
        #expect(h.emissions.count == 3)
        #expect(h.persisted.isEmpty) // Membership did not change.
    }

    @Test func queuedUploadsRecheckUntilStartingAndFinishing() {
        let h = TrackerHarness()
        h.metadata["/a"] = ItemState(isUploaded: false)
        h.work.start(paths: ["/a"])
        h.clock.fireNext()
        #expect(h.work.snapshot.items.first?.waitingUpload == true)
        #expect(h.work.snapshot.activeDirections.isEmpty)
        #expect(h.clock.active.map(\.delay) == [1])
        h.metadata["/a"] = ItemState(isUploaded: false, isUploading: true)
        h.clock.fireNext()
        #expect(h.work.snapshot.items.first?.waitingUpload == false)
        #expect(h.work.snapshot.activeDirections == .upload)
        h.metadata["/a"] = ItemState()
        h.clock.fireNext()
        #expect(h.work.snapshot.items.isEmpty)
        #expect(h.clock.active.isEmpty)
        #expect(h.persisted == [Set<String>()])
    }

    @Test func metadataFailurePreservesTransferUntilConfirmedRemoval() {
        let h = TrackerHarness()
        h.metadata["/a"] = ItemState(isUploading: true)
        h.work.start(paths: ["/a"])
        h.clock.fireNext()
        h.metadata["/a"] = ItemState(exists: false, metadataError: "Permission denied")
        h.clock.fireNext()
        #expect(h.work.snapshot.items.first?.active == .upload)
        #expect(h.work.snapshot.items.first?.error == "Permission denied")
        if case .unavailable = h.work.snapshot.availability {} else { Issue.record("Metadata failure must be visible") }
        #expect(h.persisted.isEmpty)
        h.metadata["/a"] = ItemState(exists: false)
        h.clock.fireNext()
        #expect(h.work.snapshot.items.isEmpty)
        #expect(h.work.snapshot.availability == .ready)
        #expect(h.clock.active.isEmpty)
        #expect(h.persisted == [Set<String>()])
    }

    @Test func unknownMetadataFailuresRetryRatherThanReportingFalseIdle() {
        let h = TrackerHarness()
        h.metadata["/a"] = ItemState(metadataError: "Unavailable")
        h.work.start()
        h.work.enqueue(["/a"])
        h.clock.fireNext()
        #expect(h.work.snapshot.items.isEmpty)
        #expect(h.clock.active.map(\.delay) == [1])
        if case .unavailable = h.work.snapshot.availability {} else { Issue.record("Unknown path must not look synced") }
        h.metadata["/a"] = ItemState()
        h.clock.fireNext()
        #expect(h.work.snapshot.availability == .ready)
        #expect(h.clock.active.isEmpty)
    }

    @Test func transferErrorsDoNotMakeTheMonitorUnavailable() {
        let h = TrackerHarness()
        h.metadata["/a"] = ItemState(isUploading: true, transferError: "Account access")
        h.work.start(paths: ["/a"])
        h.clock.fireNext()
        #expect(h.work.snapshot.items.first?.error == "Account access")
        #expect(h.work.snapshot.activeDirections == .upload)
        #expect(h.work.snapshot.availability == .ready)
    }

    @Test func pausedAndOfflineWorkHasNoRepeatingPassAndResumes() {
        let h = TrackerHarness()
        h.metadata["/a"] = ItemState(isUploading: true)
        h.work.start(paths: ["/a"])
        h.clock.fireNext()
        let stale = h.clock.active.first!
        h.work.pause()
        #expect(h.clock.active.isEmpty)
        stale.body()
        #expect(h.reads.count == 1)
        h.work.enqueue(["/a"])
        #expect(h.clock.active.isEmpty)
        h.work.resume()
        #expect(h.clock.active.map(\.delay) == [0])
        h.clock.fireNext()
        h.work.setReachable(false)
        #expect(h.clock.active.isEmpty)
        h.work.pause()
        h.work.setReachable(true)
        #expect(h.clock.active.isEmpty) // Reachability does not override explicit pause.
        h.work.resume()
        #expect(h.clock.active.map(\.delay) == [0])
        h.clock.fireNext()
        #expect(h.clock.active.map(\.delay) == [1])
    }

    @Test func shutdownRejectsLateCallbacksAndNewEvents() {
        let h = TrackerHarness()
        h.metadata["/a"] = ItemState(isUploading: true)
        h.work.start(paths: ["/a"])
        let stale = h.clock.active.first!
        h.work.stop()
        stale.body()
        h.work.enqueue(["/a"])
        h.work.ingest([("/a", ItemState(isDownloading: true))])
        #expect(h.reads.isEmpty)
        #expect(h.work.snapshot.items.isEmpty)
        #expect(h.clock.active.isEmpty)
    }

    @Test func rootChangesCancelObsoleteWorkAndKeepOnlyTheNewScope() {
        let h = TrackerHarness()
        h.metadata["/old/a"] = ItemState(isUploading: true)
        h.metadata["/new/b"] = ItemState(isDownloading: true)
        h.work.start(paths: ["/old/a"])
        h.clock.fireNext()
        let stale = h.clock.active.first!
        h.work.enqueue(["/old/unchecked"])
        h.work.replaceScope(keeping: { $0.hasPrefix("/new/") })
        stale.body()
        h.work.enqueue(["/new/b"])
        h.clock.fireNext()
        #expect(h.reads == ["/old/a", "/new/b"])
        #expect(h.work.snapshot.items.map(\.path) == ["/new/b"])
        #expect(h.work.snapshot.activeDirections == .download)
    }

    @Test func metadataChecksAreBoundedAndRechecksAreRoundRobin() {
        let h = TrackerHarness()
        let paths = (0..<60).map { String(format: "/%02d", $0) }
        for path in paths { h.metadata[path] = ItemState(isUploading: true) }
        h.work.start(paths: paths)
        h.clock.fireNext()
        #expect(h.reads.count == 25)
        #expect(h.clock.active.map(\.delay) == [0])
        h.clock.fireNext()
        #expect(h.reads.count == 50)
        h.clock.fireNext()
        #expect(h.reads.count == 75) // Final discovery batch shares its remaining budget with rechecks.
        #expect(h.work.snapshot.items.map(\.path) == paths)
        h.reads.removeAll()
        h.clock.fireNext()
        h.clock.fireNext()
        h.clock.fireNext()
        #expect(Set(h.reads) == Set(paths))
        #expect(h.reads.count == 75)
    }

    @Test func streamingScanRetainsOnlyCandidatesAndPublishesAvailability() {
        let h = TrackerHarness()
        h.work.start()
        h.work.setMonitor(availability: .unavailable("Dropped events; rescanning"), scanning: true)
        #expect(h.work.snapshot.isScanning)
        h.work.ingest([("/current", ItemState()), ("/z", ItemState(isUploading: true)),
                       ("/a", ItemState(isDownloading: true))])
        h.work.setMonitor(availability: .ready, scanning: false)
        #expect(h.work.snapshot.items.map(\.path) == ["/a", "/z"])
        #expect(!h.work.snapshot.isScanning)
        #expect(h.work.snapshot.availability == .ready)
        #expect(h.reads.isEmpty) // Discovery metadata is not immediately reread.
        #expect(h.clock.active.map(\.delay) == [1])
        #expect(h.persisted == [Set(["/a", "/z"])])
    }

    @Test func restoringCurrentPathsPersistsTheirRemovalWithoutAnIdleTimer() {
        let h = TrackerHarness()
        h.metadata["/a"] = ItemState()
        h.work.start(paths: ["/a"])
        h.clock.fireNext()
        #expect(h.persisted == [Set<String>()])
        #expect(h.clock.active.isEmpty)
    }

    @Test func overlappingRootsAreDeduplicatedWithPathBoundaries() {
        #expect(Tracker.deduplicatedRoots(["/cloud/Desktop", "/cloud", "/cloud", "/cloud-other"])
            == ["/cloud", "/cloud-other"])
        #expect(Tracker.deduplicatedRoots(["/cloud/../cloud/Documents", "/cloud/"])
            == ["/cloud"])
    }
}

private final class TrackerHarness {
    var metadata: [String: ItemState] = [:]
    var reads: [String] = []
    var emissions: [TrackerSnapshot] = []
    var persisted: [Set<String>] = []
    let clock = ManualTrackerScheduler()
    lazy var work: TrackerWorkState = {
        let work = TrackerWorkState(read: { [unowned self] path in
            reads.append(path)
            return metadata[path] ?? ItemState(exists: false)
        }, schedule: { [unowned self] delay, body in clock.schedule(delay, body) })
        work.onSnapshot = { [unowned self] in emissions.append($0) }
        work.persist = { [unowned self] in persisted.append($0) }
        return work
    }()
}

private final class ManualTrackerScheduler {
    final class Job {
        let delay: TimeInterval
        let body: () -> Void
        var cancelled = false
        init(delay: TimeInterval, body: @escaping () -> Void) {
            self.delay = delay
            self.body = body
        }
    }
    private var jobs: [Job] = []
    var active: [Job] { jobs.filter { !$0.cancelled } }

    func schedule(_ delay: TimeInterval, _ body: @escaping () -> Void) -> () -> Void {
        let job = Job(delay: delay, body: body)
        jobs.append(job)
        return { job.cancelled = true }
    }

    func fireNext() {
        guard let index = jobs.firstIndex(where: { !$0.cancelled }) else {
            Issue.record("Expected a scheduled tracker pass")
            return
        }
        let job = jobs.remove(at: index)
        job.body()
    }
}
