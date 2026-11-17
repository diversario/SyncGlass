import AppKit
import SwiftUI

/// Layout shared by the native window and its content. Progress never changes it.
enum StatusPanelLayout {
    static let rowHeight: CGFloat = 32
    static let inset: CGFloat = 16
    static let spacing: CGFloat = 10
    static let headerHeight: CGFloat = 48
    static let footerHeight: CGFloat = 28
    static let sectionInset: CGFloat = 12
    static let sectionHeaderHeight: CGFloat = 68
    static let chromeHeight = 2 * inset + headerHeight + footerHeight + 3 * spacing
        + 2 * (sectionHeaderHeight + 2 * sectionInset)

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
            VStack(spacing: StatusPanelLayout.spacing) {
                header.frame(height: StatusPanelLayout.headerHeight)
                DirectionSection(model: model, direction: .upload, visibleRows: rows.0,
                                 onClose: onClose, onFileInfo: onFileInfo)
                DirectionSection(model: model, direction: .download, visibleRows: rows.1,
                                 onClose: onClose, onFileInfo: onFileInfo)
                footer.frame(height: StatusPanelLayout.footerHeight)
            }
            .padding(StatusPanelLayout.inset)
        }
        .modifier(PanelSurface())
        .ignoresSafeArea(.container)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: MenuBarIcon.symbol(for: model.snapshot, isReachable: model.isReachable,
                                                stuckCount: model.stuckCount).rawValue)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.blue.gradient)
                .frame(width: 42, height: 42)
                .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("iCloud Drive")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(statusText)
                    .font(.system(size: 11))
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
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonBorderShape(.circle)
            .modifier(PanelControlStyle())
            .controlSize(.large)
            .frame(width: 36, height: 36)
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
            Button {
                onClose()
                onSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityLabel("Quit SyncGlass")
        }
        .controlSize(.small)
        .modifier(PanelControlStyle())
    }
}

private struct DirectionSection: View {
    let model: StatusModel
    let direction: TransferDirection
    let visibleRows: Int
    let onClose: () -> Void
    let onFileInfo: (String) -> Void

    private var summary: DirectionSummary { model.summary(for: direction) }

    private var tint: Color { direction == .upload ? .teal : .blue }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: direction == .upload ? "arrow.up" : "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(direction.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(summary.byteText)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .lineLimit(1)
                            .help(summary.byteText)
                    }
                    Spacer(minLength: 4)
                    Text(summary.fileCount == 1 ? "1 file" : "\(summary.fileCount) files")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.primary.opacity(0.05), in: Capsule())
                        .accessibilityLabel("\(summary.fileCount) total files")
                }
                if let availability = summary.availabilityText {
                    Text(availability)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(availability)
                }
                Spacer(minLength: 0)
                if let fraction = summary.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .accessibilityLabel("\(direction.title) byte progress")
                } else {
                    // An unknown total is not a determinate zero or an animated spinner.
                    Capsule().fill(.quaternary).frame(height: 4)
                        .accessibilityLabel("\(direction.title) byte total unavailable")
                }
            }
            .frame(height: StatusPanelLayout.sectionHeaderHeight)
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
        .padding(StatusPanelLayout.sectionInset)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
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
    @State private var isHovered = false

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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: max(56, (geometry.size.width - 100) * 0.3), alignment: .leading)
                Text(filename)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 6)
            .frame(height: StatusPanelLayout.rowHeight)
            .background(.primary.opacity(isHovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8))
            .onHover { isHovered = $0 }
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

private struct PanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}

private struct PanelControlStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
