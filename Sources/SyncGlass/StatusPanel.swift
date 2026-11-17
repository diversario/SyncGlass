import AppKit
import SwiftUI

/// Layout shared by the native window and its content. Progress never changes it.
enum StatusPanelLayout {
    static let rowHeight: CGFloat = 32
    static let chromeHeight: CGFloat = 279

    static func preferredHeight(uploads: Int, downloads: Int) -> CGFloat {
        chromeHeight + CGFloat(min(10, max(1, uploads)) + min(10, max(1, downloads))) * rowHeight
    }

    static func visibleRows(uploads: Int, downloads: Int, height: CGFloat) -> (Int, Int) {
        var up = min(10, max(1, uploads))
        var down = min(10, max(1, downloads))
        let budget = max(2, Int((height - chromeHeight) / rowHeight))
        while up + down > budget {
            if up >= down && up > 1 { up -= 1 }
            else if down > 1 { down -= 1 }
        }
        return (up, down)
    }
}

struct StatusPanel: View {
    let model: StatusModel
    let onSettings: () -> Void
    let onClose: () -> Void
    let onFileInfo: (String) -> Void

    var body: some View {
        GeometryReader { geometry in
            let rows = StatusPanelLayout.visibleRows(
                uploads: model.uploads.fileCount, downloads: model.downloads.fileCount,
                height: geometry.size.height)
            VStack(spacing: 0) {
                header.frame(height: 52)
                DirectionSection(model: model, direction: .upload, visibleRows: rows.0,
                                 onClose: onClose, onFileInfo: onFileInfo)
                Divider()
                DirectionSection(model: model, direction: .download, visibleRows: rows.1,
                                 onClose: onClose, onFileInfo: onFileInfo)
                Spacer(minLength: 0)
                footer.frame(height: 42)
            }
            .padding(12)
        }
        .background(.regularMaterial)
        .ignoresSafeArea(.container)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: MenuBarIcon.symbol(for: model.snapshot, isReachable: model.isReachable,
                                                stuckCount: model.stuckCount).rawValue)
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("iCloud Drive").font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(statusText)
            }
            Spacer(minLength: 4)
            Menu {
                Button(model.isWatchingForStuckFiles ? "Stop Watching for Stuck Files" : "Watch for Stuck Files") {
                    model.toggleStuckFileWatch()
                }
                .disabled(model.isPreview)
                Button("Scan for Transfers…") {
                    onClose()
                    Scanner.scanWithPanel()
                }
                .disabled(model.isPreview)
                Divider()
                Button("About SyncGlass") {
                    onClose()
                    model.showAbout()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
    }

    private var statusText: String {
        if !model.isReachable { return "Offline — transfer activity may be stale" }
        if case .unavailable(let reason) = model.snapshot.availability { return "Monitoring unavailable: \(reason)" }
        if model.isWatchingForStuckFiles {
            return model.lastStuckFileCheck == nil ? "Checking for stuck files…" : "Watching for stuck files · \(model.stuckCount) stuck"
        }
        if model.isPreview { return "Synthetic preview — not live iCloud data" }
        if model.snapshot.isScanning { return "Scanning for transfers…" }
        if model.snapshot.items.isEmpty { return "No observed transfers" }
        return "Current transfers reported by macOS"
    }

    private var footer: some View {
        HStack {
            Button("Settings…") {
                onClose()
                onSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button("Quit SyncGlass") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .controlSize(.small)
    }
}

private struct DirectionSection: View {
    let model: StatusModel
    let direction: TransferDirection
    let visibleRows: Int
    let onClose: () -> Void
    let onFileInfo: (String) -> Void

    private var summary: DirectionSummary { model.summary(for: direction) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(direction.title, systemImage: direction == .upload ? "arrow.up" : "arrow.down")
                        .font(.headline)
                    Spacer()
                    Text("\(summary.fileCount) total files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(summary.byteText)
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(summary.byteText)
                Text(summary.availabilityText ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(summary.availabilityText ?? "")
                if let fraction = summary.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("\(direction.title) byte progress")
                } else {
                    // An unknown total is not a determinate zero or an animated spinner.
                    Capsule().fill(.quaternary).frame(height: 4)
                        .accessibilityLabel("\(direction.title) byte total unavailable")
                }
            }
            .frame(height: 80)
            if summary.items.isEmpty {
                Text(direction == .upload ? "No uploads observed" : "No downloads observed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: StatusPanelLayout.rowHeight)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(summary.items) { item in
                            TransferRow(item: item, direction: direction, model: model,
                                        onClose: onClose, onFileInfo: onFileInfo)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: CGFloat(visibleRows) * StatusPanelLayout.rowHeight)
            }
        }
    }
}

private struct TransferRow: View {
    let item: TransferItem
    let direction: TransferDirection
    let model: StatusModel
    let onClose: () -> Void
    let onFileInfo: (String) -> Void
    private let filename: String
    private let parentName: String

    init(item: TransferItem, direction: TransferDirection, model: StatusModel,
         onClose: @escaping () -> Void, onFileInfo: @escaping (String) -> Void) {
        self.item = item
        self.direction = direction
        self.model = model
        self.onClose = onClose
        self.onFileInfo = onFileInfo
        filename = (item.path as NSString).lastPathComponent
        parentName = ((item.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 8) {
                Text(parentName)
                    .foregroundStyle(.secondary)
                    .frame(width: max(56, (geometry.size.width - 100) * 0.3), alignment: .leading)
                Text(filename)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 76, alignment: .trailing)
            }
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 4)
            .frame(height: StatusPanelLayout.rowHeight)
            .contentShape(Rectangle())
            .help(helpText)
            .contextMenu {
                Button("Show in Finder") {
                    onClose()
                    model.reveal(item.path)
                }
                .disabled(model.isPreview)
                Button("Get Info") {
                    onClose()
                    onFileInfo(item.path)
                }
                .disabled(model.isPreview)
            }
            .onTapGesture(count: 2) {
                guard !model.isPreview else { return }
                onClose()
                model.reveal(item.path)
            }
        }
        .frame(height: StatusPanelLayout.rowHeight)
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            model.setVisible(item.path, direction: direction, visible: visible)
        }
        .onDisappear { model.setVisible(item.path, direction: direction, visible: false) }
        .accessibilityElement(children: .combine)
    }

    private var helpText: String {
        let error = item.error ?? model.transferError(for: item.path)
        return error.map { "\(item.path)\n\($0)" } ?? item.path
    }

    private var progressText: String {
        if item.error != nil || model.transferError(for: item.path) != nil { return "Error" }
        if model.isStuck(item.path) { return "Stuck" }
        if direction == .upload && item.waitingUpload && !item.active.contains(.upload) { return "Waiting" }
        guard let progress = model.progress(for: item.path, direction: direction) else { return "Unknown" }
        return progress.fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
