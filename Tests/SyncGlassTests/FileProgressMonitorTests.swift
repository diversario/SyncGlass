import Foundation
import Testing
@testable import SyncGlass

@Suite struct FileProgressMonitorTests {
    @Test func packageBytesDoNotUseAChildOrAnUnidentifiedOperation() {
        let source = FileProgressSource()
        let monitor = FileProgressMonitor(subscribe: source.subscribe, unsubscribe: source.unsubscribe)
        let path = "/test/Library.bundle"
        monitor.track([path])
        let parent = source.progress(path, completed: 25, total: 100)
        let end = source.handlers[0](parent)
        #expect(monitor.progressByPath()[path]?.completedBytes == 25)
        #expect(monitor.progressByPath()[path]?.totalBytes == 100)
        let child = source.progress(path + "/Contents/data", completed: 900, total: 1000)
        #expect(source.handlers[0](child) == nil)
        let unidentified = Progress(totalUnitCount: 500)
        unidentified.kind = .file
        #expect(source.handlers[0](unidentified) == nil)
        #expect(monitor.progressByPath()[path]?.totalBytes == 100)
        parent.completedUnitCount = 50
        #expect(monitor.progressByPath()[path]?.completedBytes == 50)
        end?()
        #expect(monitor.progressByPath()[path] == nil)
    }

    @Test func closingReleasesSubscriptionsAndRejectsOldPublicationsAfterReopening() {
        let source = FileProgressSource()
        let monitor = FileProgressMonitor(subscribe: source.subscribe, unsubscribe: source.unsubscribe)
        let path = "/test/file.bin"
        monitor.track([path])
        let old = source.handlers[0]
        let endOld = old(source.progress(path, completed: 10, total: 100))
        monitor.track([String]())
        #expect(monitor.subscriptionCount == 0)
        #expect(source.removed == [0])
        #expect(monitor.progressByPath().isEmpty)
        monitor.track([path])
        _ = source.handlers[1](source.progress(path, completed: 40, total: 200))
        endOld?()
        _ = old(source.progress(path, completed: 99, total: 100))
        #expect(monitor.progressByPath()[path]?.completedBytes == 40)
        #expect(monitor.progressByPath()[path]?.totalBytes == 200)
    }
}

private final class FileProgressSource {
    var handlers: [FileProgressMonitor.PublishingHandler] = []
    var removed: [Int] = []

    func subscribe(_ url: URL, publishing: @escaping FileProgressMonitor.PublishingHandler) -> Any {
        handlers.append(publishing)
        return handlers.count - 1
    }

    func unsubscribe(_ token: Any) { removed.append(token as! Int) }

    func progress(_ path: String, completed: Int64, total: Int64) -> Progress {
        let progress = Progress(totalUnitCount: total)
        progress.kind = .file
        progress.completedUnitCount = completed
        progress.setUserInfoObject(URL(fileURLWithPath: path), forKey: .fileURLKey)
        return progress
    }
}
