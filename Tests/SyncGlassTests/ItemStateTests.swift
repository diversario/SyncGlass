import Foundation
import Testing
@testable import SyncGlass

@Suite struct ItemStateTests {
    @Test func uploadedAndIdleIsCurrent() {
        #expect(ItemState().phase(trackDownloads: true) == .current)
    }

    @Test func notUploadedIsWaitingWithoutAnActiveArrow() {
        #expect(ItemState(isUploaded: false).phase(trackDownloads: true)
            == .inFlight(active: [], waitingUpload: true))
    }

    @Test func uploadingIsActiveRatherThanWaiting() {
        #expect(ItemState(isUploaded: false, isUploading: true).phase(trackDownloads: true)
            == .inFlight(active: .upload, waitingUpload: false))
    }

    @Test func bothFlagsRemainBothDirections() {
        #expect(ItemState(isUploading: true, isDownloading: true).phase(trackDownloads: true)
            == .inFlight(active: [.upload, .download], waitingUpload: false))
    }

    @Test func waitingUploadCanAlsoBeDownloading() {
        #expect(ItemState(isUploaded: false, isDownloading: true).phase(trackDownloads: true)
            == .inFlight(active: .download, waitingUpload: true))
    }

    @Test func downloadCountsOnlyWhenTracked() {
        let state = ItemState(isDownloading: true)
        #expect(state.phase(trackDownloads: true) == .inFlight(active: .download, waitingUpload: false))
        #expect(state.phase(trackDownloads: false) == .current)
    }

    @Test func cloudOnlyDoesNotImplyActiveDownload() {
        #expect(ItemState(isCurrent: false).phase(trackDownloads: true) == .current)
    }

    @Test func missingAndNonUbiquitousPathsAreIgnored() {
        #expect(ItemState(exists: false, isUploaded: false).phase(trackDownloads: true) == .ignored)
        #expect(ItemState(isUbiquitous: false, isUploaded: false).phase(trackDownloads: true) == .ignored)
    }

    @Test func metadataFailureIsNotDeletionOrCompletion() {
        #expect(ItemState(exists: false, metadataError: "Permission denied").phase(trackDownloads: true)
            == .unavailable("Permission denied"))
    }

    @Test func reportedTransferErrorDoesNotDiscardActivity() {
        let state = ItemState(isUploading: true, transferError: "Account access temporarily unavailable")
        #expect(state.phase(trackDownloads: true) == .inFlight(active: .upload, waitingUpload: false))
        #expect(state.transferError == "Account access temporarily unavailable")
    }

    @Test func containsBytesDoesNotRequireRecursivePackageSizing() {
        #expect(ItemState(fileSize: 1).containsBytes)
        #expect(ItemState(isDirectory: true, isPackage: true).containsBytes)
        #expect(!ItemState(fileSize: 0).containsBytes)
    }
}
/// File metadata outside iCloud.
/// Each test gets its own folder; `deinit` deletes it.
@Suite final class ItemStateFileTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncGlassTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, contents: String = "abc") throws -> String {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url.path
    }

    @Test func regularFile() throws {
        let state = ItemState(url: URL(fileURLWithPath: try file("a.txt")))
        #expect(state.exists)
        #expect(!state.isUbiquitous)
        #expect(!state.isDirectory)
        #expect(state.fileSize == 3)
        #expect(state.containsBytes)
        #expect(state.phase(trackDownloads: true) == .ignored)
    }

    @Test func emptyFileContainsNoBytes() throws {
        #expect(!ItemState(url: URL(fileURLWithPath: try file("empty.txt", contents: ""))).containsBytes)
    }

    @Test func hiddenFile() throws {
        #expect(ItemState(url: URL(fileURLWithPath: try file(".hidden"))).isHidden)
    }

    @Test func directory() {
        let state = ItemState(url: folder)
        #expect(state.isDirectory)
        #expect(state.containsBytes)
    }

    @Test func symbolicLink() throws {
        let target = try file("target.txt")
        let link = folder.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(ItemState(url: URL(fileURLWithPath: link)).isSymbolicLink)
    }

    @Test func missingPath() {
        let state = ItemState(url: folder.appendingPathComponent("missing"))
        #expect(!state.exists)
        #expect(state.phase(trackDownloads: true) == .ignored)
    }
}
