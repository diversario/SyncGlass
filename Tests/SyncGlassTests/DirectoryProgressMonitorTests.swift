import Foundation
import Testing
@testable import SyncGlass

@Suite struct DirectoryProgressMonitorTests {
    @Test func overlappingOperationsDoNotUnpublishEachOther() {
        let h = DirectoryProgressHarness()
        h.watch("/root")
        let first = h.progress("/root/file")
        let second = h.progress("/root/file")
        let endFirst = h.publish(first)
        let endSecond = h.publish(second)
        h.drain()
        #expect(h.publicationCount == 1)
        #expect(h.events == [.init("/root/file", true), .init("/root/file", true)])

        endFirst?()
        h.drain()
        #expect(h.publicationCount == 1)
        #expect(h.events.count == 2)
        first.completedUnitCount = 10
        h.drain()
        #expect(h.events.count == 2)
        second.completedUnitCount = 10
        h.drain()
        #expect(h.events.last == .init("/root/file", true))
        #expect(h.events.count == 3)

        endSecond?()
        endFirst?()
        h.drain()
        #expect(h.publicationCount == 0)
        #expect(h.events == [
            .init("/root/file", true), .init("/root/file", true),
            .init("/root/file", true), .init("/root/file", false),
        ])
    }

    @Test func separatePublicationsCanReuseTheSameProgressObject() {
        let h = DirectoryProgressHarness()
        h.watch("/root")
        let progress = h.progress("/root/file")
        let first = h.publish(progress)
        let second = h.publish(progress)
        h.drain()
        first?()
        h.drain()
        #expect(h.publicationCount == 1)
        #expect(h.events.count == 2)
        second?()
        h.drain()
        #expect(h.publicationCount == 0)
        #expect(h.events.last == .init("/root/file", false))
    }

    @Test func removedAndRewatchedDirectoryRejectsAllOldCallbackKinds() {
        let h = DirectoryProgressHarness()
        h.watch("/root")
        let oldSubscription = h.subscriptions[0]
        let oldProgress = h.progress("/root/file")
        let oldEnd = h.publish(oldProgress, through: oldSubscription)
        h.drain()
        let queuedProgress = h.progress("/root/queued")
        h.onQueue {
            oldProgress.completedUnitCount = 1 // Queue a KVO callback behind this block.
            _ = oldSubscription.publishing(queuedProgress)
            h.monitor.removeSubtree("/root")
            h.monitor.watch(URL(fileURLWithPath: "/root", isDirectory: true))
        }
        h.drain()
        #expect(h.events == [.init("/root/file", true), .init("/root/file", false)])
        #expect(h.removed == [oldSubscription.id])
        #expect(h.publicationCount == 0)

        let current = h.progress("/root/file")
        let currentEnd = h.publish(current)
        h.drain()
        let before = h.events
        oldEnd?()
        _ = oldSubscription.publishing(h.progress("/root/stale"))
        oldProgress.totalUnitCount = 200
        h.drain()
        #expect(h.events == before)
        #expect(h.publicationCount == 1)
        currentEnd?()
        h.drain()
        #expect(h.events.last == .init("/root/file", false))
    }

    @Test func stopRejectsQueuedAndLateCallbacksUntilExplicitlyWatchedAgain() {
        let h = DirectoryProgressHarness()
        h.watch("/root")
        let subscription = h.subscriptions[0]
        let progress = h.progress("/root/file")
        let end = h.publish(progress)
        h.drain()
        h.onQueue {
            progress.completedUnitCount = 1
            _ = subscription.publishing(h.progress("/root/queued"))
            h.monitor.stop()
        }
        h.drain()
        let stoppedEvents = h.events
        #expect(stoppedEvents == [.init("/root/file", true), .init("/root/file", false)])
        #expect(h.publicationCount == 0)
        #expect(h.onQueue { h.monitor.directoryCount } == 0)
        end?()
        progress.totalUnitCount = 200
        _ = subscription.publishing(h.progress("/root/late"))
        h.onQueue { h.monitor.stop() }
        h.drain()
        #expect(h.events == stoppedEvents)
        #expect(h.removed == [subscription.id])

        h.watch("/root")
        _ = h.publish(h.progress("/root/new"))
        h.drain()
        #expect(h.publicationCount == 1)
        #expect(h.events.last == .init("/root/new", true))
    }

    @Test func movementWakesMetadataAndUnpublicationReleasesProgressAndObservers() {
        let h = DirectoryProgressHarness()
        h.watch("/root")
        weak var retainedProgress: Progress?
        autoreleasepool {
            let progress = h.progress("/root/file")
            retainedProgress = progress
            let end = h.publish(progress)
            h.drain()
            progress.completedUnitCount = 10
            h.drain()
            #expect(h.events.count == 2)
            #expect(h.events.last == .init("/root/file", true))
            progress.totalUnitCount = 200
            h.drain()
            #expect(h.events.count == 3)
            progress.completedUnitCount = 10
            progress.totalUnitCount = 200
            h.drain()
            #expect(h.events.count == 3)
            // Byte completion can precede the metadata direction flag.
            progress.completedUnitCount = 200
            h.drain()
            #expect(h.publicationCount == 1)
            #expect(h.events.last == .init("/root/file", true))
            end?()
            h.drain()
            #expect(h.publicationCount == 0)
            #expect(h.events.last == .init("/root/file", false))
            let endedEvents = h.events
            progress.totalUnitCount = 300
            progress.completedUnitCount = 250
            end?()
            h.drain()
            #expect(h.events == endedEvents)
        }
        h.drain()
        #expect(retainedProgress == nil)
    }

    @Test func completionOfAnOverlappingOperationStillWakesMetadata() {
        let h = DirectoryProgressHarness()
        h.watch("/root")
        let first = h.progress("/root/file")
        let second = h.progress("/root/file")
        _ = h.publish(first)
        _ = h.publish(second)
        h.drain()
        first.completedUnitCount = 100
        h.drain()
        #expect(h.publicationCount == 1)
        #expect(h.events == [
            .init("/root/file", true), .init("/root/file", true), .init("/root/file", true),
        ])
        first.totalUnitCount = 200
        h.drain()
        #expect(h.events.count == 4)
    }

    @Test func finishedAndCancelledProgressStayCandidatesUntilUnpublication() {
        let h = DirectoryProgressHarness()
        h.watch("/root")
        let completed = h.progress("/root/completed")
        completed.completedUnitCount = 100
        let cancelled = h.progress("/root/cancelled")
        cancelled.cancel()
        let endCompleted = h.publish(completed)
        let endCancelled = h.publish(cancelled)
        h.drain()
        #expect(h.publicationCount == 2)
        #expect(h.events == [.init("/root/completed", true), .init("/root/cancelled", true)])
        endCompleted?()
        endCancelled?()
        h.drain()
        #expect(h.publicationCount == 0)
        #expect(h.events.suffix(2) == [.init("/root/completed", false), .init("/root/cancelled", false)])
    }

    @Test func subtreeRemovalOnlyCleansMatchingDirectories() {
        let h = DirectoryProgressHarness()
        let paths = ["/root", "/root/removed", "/root/removed/deep", "/root/removed-other", "/else"]
        for path in paths { h.watch(path) }
        let progress = paths.map { h.progress($0 + "/file") }
        for (subscription, operation) in zip(h.subscriptions, progress) {
            _ = h.publish(operation, through: subscription)
        }
        h.drain()
        h.onQueue { h.monitor.removeSubtree("/root/removed") }
        h.drain()
        #expect(Set(h.removed) == [1, 2])
        #expect(h.onQueue { h.monitor.directoryCount } == 3)
        #expect(h.publicationCount == 3)
        #expect(Set(h.events.filter { !$0.published }.map(\.path)) == [
            "/root/removed/file", "/root/removed/deep/file",
        ])
        let before = h.events.count
        progress[1].completedUnitCount = 1
        progress[2].completedUnitCount = 1
        h.drain()
        #expect(h.events.count == before)
        progress[3].completedUnitCount = 1
        h.drain()
        #expect(h.events.count == before + 1)
        #expect(h.events.last == .init("/root/removed-other/file", true))
        h.onQueue { h.monitor.removeSubtree("/") }
        #expect(h.onQueue { h.monitor.directoryCount } == 0)
        #expect(h.publicationCount == 0)
        #expect(Set(h.removed) == Set(0..<5))
    }

    @Test func reconciliationPreservesTokensAndHasNoSubscriptionCeiling() {
        let h = DirectoryProgressHarness()
        let paths = (0..<750).map { "/root/\($0)" }
        for path in paths { h.watch(path) }
        h.watch("/root/0/child/..")
        #expect(h.onQueue { h.monitor.directoryCount } == 750)
        #expect(h.subscriptions.count == 750)
        let retainedProgress = h.progress("/root/0/file")
        _ = h.publish(retainedProgress, through: h.subscriptions[0])
        _ = h.publish(h.progress("/root/749/file"), through: h.subscriptions[749])
        h.drain()
        h.onQueue { h.monitor.retainDirectories(Set(paths.dropLast())) }
        #expect(h.removed == [749])
        #expect(h.onQueue { h.monitor.directoryCount } == 749)
        #expect(h.publicationCount == 1)
        #expect(h.onQueue { h.monitor.containsDirectory("/root/0") })
        #expect(!h.onQueue { h.monitor.containsDirectory("/root/749") })
        retainedProgress.completedUnitCount = 1
        h.drain()
        #expect(h.events.last == .init("/root/0/file", true))
        h.watch("/root/0")
        #expect(h.subscriptions.count == 750)
    }

    @Test func acceptsOnlyFileProgressWithARealFileURL() {
        let h = DirectoryProgressHarness()
        h.watch("/root")
        let nonFile = Progress(totalUnitCount: 100)
        nonFile.setUserInfoObject(URL(fileURLWithPath: "/root/non-file"), forKey: .fileURLKey)
        let missingURL = Progress(totalUnitCount: 100)
        missingURL.kind = .file
        let remoteURL = Progress(totalUnitCount: 100)
        remoteURL.kind = .file
        remoteURL.setUserInfoObject(URL(string: "https://example.com/file")!, forKey: .fileURLKey)
        #expect(h.publish(nonFile) == nil)
        #expect(h.publish(missingURL) == nil)
        #expect(h.publish(remoteURL) == nil)
        _ = h.publish(h.progress("/root/child/../real-file"))
        h.drain()
        #expect(h.publicationCount == 1)
        #expect(h.events == [.init("/root/real-file", true)])
    }

    @Test func deinitializationRemovesSubscriberTokensAndLiveObservers() {
        let h = DirectoryProgressHarness()
        h.watch("/root")
        weak var retainedProgress: Progress?
        autoreleasepool {
            let progress = h.progress("/root/file")
            retainedProgress = progress
            let end = h.publish(progress)
            h.drain()
            h.onQueue { h.monitor = nil }
            #expect(h.removed == [0])
            let before = h.events
            progress.completedUnitCount = 1
            end?()
            h.drain()
            #expect(h.events == before)
        }
        h.drain()
        #expect(retainedProgress == nil)
    }
}

private final class DirectoryProgressHarness {
    struct Event: Equatable {
        let path: String
        let published: Bool

        init(_ path: String, _ published: Bool) {
            self.path = path
            self.published = published
        }
    }

    final class Subscription {
        let id: Int
        let publishing: DirectoryProgressMonitor.PublishingHandler

        init(id: Int, publishing: @escaping DirectoryProgressMonitor.PublishingHandler) {
            self.id = id
            self.publishing = publishing
        }
    }

    let queue = DispatchQueue(label: "SyncGlass.test.directory-progress", autoreleaseFrequency: .workItem)
    var monitor: DirectoryProgressMonitor!
    var subscriptions: [Subscription] = []
    var removed: [Int] = []
    var events: [Event] = []

    init() {
        monitor = DirectoryProgressMonitor(queue: queue, changed: { [weak self] path, published in
            self?.events.append(Event(path, published))
        }, subscribe: { [weak self] _, publishing in
            guard let self else { preconditionFailure("Harness released during subscription") }
            let subscription = Subscription(id: self.subscriptions.count, publishing: publishing)
            self.subscriptions.append(subscription)
            return subscription
        }, unsubscribe: { [weak self] token in
            self?.removed.append((token as! Subscription).id)
        })
    }

    var publicationCount: Int { onQueue { monitor.publicationCount } }

    func onQueue<T>(_ body: () -> T) -> T { queue.sync(execute: body) }
    func drain() { onQueue {} }

    func watch(_ path: String) {
        onQueue { monitor.watch(URL(fileURLWithPath: path, isDirectory: true)) }
    }

    func progress(_ path: String) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        progress.kind = .file
        progress.setUserInfoObject(URL(fileURLWithPath: path), forKey: .fileURLKey)
        return progress
    }

    @discardableResult
    func publish(_ progress: Progress, through subscription: Subscription? = nil) -> (() -> Void)? {
        (subscription ?? subscriptions.last!).publishing(progress)
    }
}
