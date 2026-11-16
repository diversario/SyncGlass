import AppKit
import Testing
@testable import SyncGlass

@MainActor @Suite struct MenuBarSymbolTests {
    private func snapshot(_ directions: TransferDirections = [], waiting: Bool = false,
                          availability: MonitorAvailability = .ready) -> TrackerSnapshot {
        TrackerSnapshot(items: [TransferItem(path: "/Preview/file.bin", active: directions,
                                              waitingUpload: waiting)], availability: availability)
    }

    @Test func activeDirectionSymbols() {
        #expect(MenuBarIcon.symbol(for: snapshot(.upload), isReachable: true) == .uploading)
        #expect(MenuBarIcon.symbol(for: snapshot(.download), isReachable: true) == .downloading)
        #expect(MenuBarIcon.symbol(for: snapshot([.upload, .download]), isReachable: true) == .both)
        #expect(MenuBarIcon.Symbol.both.rawValue == "arrow.up.arrow.down")
    }

    @Test func bothDirectionsAcrossDifferentFiles() {
        let state = TrackerSnapshot(items: [
            TransferItem(path: "/Preview/up", active: .upload),
            TransferItem(path: "/Preview/down", active: .download),
        ])
        #expect(MenuBarIcon.symbol(for: state, isReachable: true) == .both)
        let label = MenuBarIcon.accessibilityLabel(for: state, isReachable: true)
        #expect(label.contains("uploading"))
        #expect(label.contains("downloading"))
    }

    @Test func queuedWorkDoesNotClaimActiveUpload() {
        let state = snapshot(waiting: true)
        #expect(MenuBarIcon.symbol(for: state, isReachable: true) == .idle)
        let label = MenuBarIcon.accessibilityLabel(for: state, isReachable: true)
        #expect(label.contains("waiting to upload"))
        #expect(!label.contains("uploading"))
    }

    @Test func queuedUploadDoesNotHideActiveDownload() {
        #expect(MenuBarIcon.symbol(for: snapshot(.download, waiting: true), isReachable: true) == .downloading)
    }

    @Test func idleDoesNotPromiseServerSynchronization() {
        let state = TrackerSnapshot()
        #expect(MenuBarIcon.symbol(for: state, isReachable: true) == .idle)
        #expect(MenuBarIcon.accessibilityLabel(for: state, isReachable: true) == "SyncGlass: no observed transfers")
    }

    @Test func offlineAndUnavailableAreExplicit() {
        let state = snapshot([.upload, .download], availability: .unavailable("Permission denied"))
        #expect(MenuBarIcon.symbol(for: state, isReachable: false, stuckCount: 2) == .offline)
        #expect(MenuBarIcon.symbol(for: state, isReachable: true) == .unavailable)
        let label = MenuBarIcon.accessibilityLabel(for: state, isReachable: false)
        #expect(label.contains("offline"))
        #expect(label.contains("monitoring unavailable: Permission denied"))
    }

    @Test func diagnosticDoesNotHideActiveArrows() {
        for directions in [TransferDirections.upload, .download, [.upload, .download]] {
            #expect(MenuBarIcon.symbol(for: snapshot(directions), isReachable: true, stuckCount: 1) ==
                    MenuBarIcon.symbol(for: snapshot(directions), isReachable: true))
        }
        #expect(MenuBarIcon.symbol(for: TrackerSnapshot(), isReachable: true, stuckCount: 1) == .stuck)
        #expect(MenuBarIcon.accessibilityLabel(for: snapshot(.upload), isReachable: true, stuckCount: 2)
            .contains("2 stuck files"))
    }

    @Test func sameCountDirectionChangeChangesSymbol() {
        #expect(MenuBarIcon.symbol(for: snapshot(.upload), isReachable: true) !=
                MenuBarIcon.symbol(for: snapshot(.download), isReachable: true))
    }

    @Test func cachedImagesAreTemplateImages() {
        let first = MenuBarIcon.image(for: snapshot(.upload), isReachable: true)
        let second = MenuBarIcon.image(for: snapshot(.upload), isReachable: true)
        #expect(first === second)
        #expect(first.isTemplate)
    }
}
