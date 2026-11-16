import Foundation
import Testing
@testable import SyncGlass

@Suite struct TransferSummaryTests {
    private func progress(_ current: Int64, _ total: Int64, direction: FileProgress.Direction? = nil) -> FileProgress {
        FileProgress(direction: direction, fraction: 0, completedBytes: current, totalBytes: total)
    }

    @Test func includesOffscreenFilesAndUnknownProgressBeyondSubscriptionLimit() {
        let items = (0..<501).map { TransferItem(path: "/test/\($0)", active: .upload) }
        let reports = Dictionary(uniqueKeysWithValues: items.prefix(500).map { ($0.path, progress(50, 100)) })
        let summary = DirectionSummary(items: items, direction: .upload, progress: reports)
        #expect(summary.fileCount == 501)
        #expect(summary.completedBytes == 25_000)
        #expect(summary.totalBytes == 50_000)
        #expect(summary.unavailableCount == 1)
        #expect(summary.fraction == nil)
    }

    @Test func separatesDirectionsAndCountsBothFlaggedPathWithinEach() {
        let items = [TransferItem(path: "/upload", active: .upload),
                     TransferItem(path: "/download", active: .download),
                     TransferItem(path: "/both", active: [.upload, .download])]
        let reports = ["/upload": progress(20, 100), "/download": progress(30, 200),
                       "/both": progress(40, 300, direction: .downloading)]
        let up = DirectionSummary(items: items, direction: .upload, progress: reports)
        let down = DirectionSummary(items: items, direction: .download, progress: reports)
        #expect(up.fileCount == 2)
        #expect(up.completedBytes == 20)
        #expect(up.unavailableCount == 1)
        #expect(down.fileCount == 2)
        #expect(down.completedBytes == 70)
        #expect(down.totalBytes == 500)
        #expect(down.fraction == 0.14)
    }

    @Test func missingOperationKindUsesOnlyAnUnambiguousActiveDirection() {
        let item = TransferItem(path: "/both", active: [.upload, .download])
        for direction in TransferDirection.allCases {
            let summary = DirectionSummary(items: [item], direction: direction, progress: [item.path: progress(5, 10)])
            #expect(summary.fraction == nil)
            #expect(summary.unavailableCount == 1)
        }
    }

    @Test func waitingFilesDoNotReuseOldProgress() {
        let item = TransferItem(path: "/waiting", waitingUpload: true)
        let summary = DirectionSummary(items: [item], direction: .upload, progress: [item.path: progress(5, 10)])
        #expect(summary.fileCount == 1)
        #expect(summary.unavailableCount == 1)
        #expect(summary.completedBytes == 0)
        #expect(summary.fraction == nil)
    }

    @Test func overflowCannotAppearComplete() {
        let items = [TransferItem(path: "/a", active: .upload), TransferItem(path: "/b", active: .upload)]
        let reports = ["/a": progress(1, .max), "/b": progress(1, .max)]
        let summary = DirectionSummary(items: items, direction: .upload, progress: reports)
        #expect(summary.overflowed)
        #expect(summary.fraction == nil)
    }

    @Test func invalidCountsRemainUnknownAndOvershootIsClamped() {
        let a = TransferItem(path: "/a", active: .upload)
        for report in [progress(-1, 100), progress(0, 0), progress(2, -1)] {
            let summary = DirectionSummary(items: [a], direction: .upload, progress: [a.path: report])
            #expect(summary.unavailableCount == 1)
            #expect(summary.fraction == nil)
        }
        let clamped = DirectionSummary(items: [a], direction: .upload, progress: [a.path: progress(120, 100)])
        #expect(clamped.completedBytes == 100)
        #expect(clamped.fraction == 1)
    }

    @Test func acceptsOnlyValidPublishedFileUnits() {
        let p = Progress(totalUnitCount: 100)
        p.completedUnitCount = 25
        #expect(FileProgress.read(p) == nil)
        p.kind = .file
        #expect(FileProgress.read(p)?.completedBytes == 25)
        p.totalUnitCount = 0
        #expect(FileProgress.read(p) == nil)
        p.totalUnitCount = 100
        p.completedUnitCount = -1
        #expect(FileProgress.read(p) == nil)
        p.completedUnitCount = 25
        p.cancel()
        #expect(FileProgress.read(p) == nil)
    }

    @Test func unpublishedProgressRevertsToUnknown() {
        let item = TransferItem(path: "/a", active: .upload)
        var summary = DirectionSummary(items: [item], direction: .upload, progress: [item.path: progress(25, 100)])
        #expect(summary.fraction == 0.25)
        summary.updateProgress(direction: .upload, progress: [:])
        #expect(summary.fraction == nil)
        #expect(summary.unavailableCount == 1)
    }

    @MainActor @Test func finishedFileLeavesItsSection() {
        let model = StatusModel()
        model.isPreview = true
        model.update(TrackerSnapshot(items: [TransferItem(path: "/a", active: .download)]))
        #expect(model.downloads.fileCount == 1)
        model.update(TrackerSnapshot())
        #expect(model.downloads.fileCount == 0)
        #expect(model.uploads.fileCount == 0)
        #expect(model.downloads.totalBytes == 0)
    }
}
