import AppKit
import SwiftUI

@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let model: StatusModel
    private let statusItem: NSStatusItem
    private let panel: TransferPanel
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var trackingMenus = 0
    private var layingOut = false
    private var preferredWidth: CGFloat = 520
    private var loadedWidth = false

    /// The app delegate owns on-demand File Info windows, not the panel.
    var onFileInfo: ((String) -> Void)?
    var isVisible: Bool { panel.isVisible }

    #if DEBUG
    var verificationWindowID: Int { panel.windowNumber }
    var verificationFrame: NSRect { panel.frame }
    var verificationStatusButtonRect: NSRect { anchor ?? .zero }
    #endif

    init(model: StatusModel, onSettings: @escaping () -> Void) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        panel = TransferPanel(contentRect: NSRect(x: 0, y: 0, width: 520,
                                                 height: StatusPanelLayout.preferredHeight(uploads: 0, downloads: 0)),
                              styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = "SyncGlass Transfers"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.onEscape = { [weak self] in self?.close() }
        let root = StatusPanel(model: model, onSettings: onSettings,
                               onClose: { [weak self] in self?.close() },
                               onFileInfo: { [weak self] path in
                                   guard let self, !self.model.isPreview else { return }
                                   self.onFileInfo?(path)
                               })
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        panel.contentViewController = host
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp])
        }
        model.onChange = { [weak self] in self?.refresh() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    deinit {
        MainActor.assumeIsolated {
            removeDismissalMonitors()
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func refresh() {
        let label = MenuBarIcon.accessibilityLabel(for: model.snapshot, isReachable: model.isReachable,
                                                  stuckCount: model.stuckCount)
        statusItem.button?.image = MenuBarIcon.image(for: model.snapshot, isReachable: model.isReachable,
                                                    stuckCount: model.stuckCount)
        statusItem.button?.toolTip = label
        statusItem.button?.setAccessibilityLabel(label)
        if isVisible && !panel.inLiveResize { positionPanel() }
    }

    func show() {
        guard !isVisible else { return }
        if !loadedWidth {
            loadedWidth = true
            if !model.isPreview {
                let saved = Prefs.store.double(forKey: PrefKey.panelWidth)
                if saved.isFinite && saved > 0 { preferredWidth = saved }
            }
        }
        model.openPanel()
        positionPanel()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
        statusItem.button?.highlight(true)
        installDismissalMonitors()
    }

    func close() {
        removeDismissalMonitors()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        model.closePanel()
    }

    @objc private func toggle() {
        if isVisible { close() } else { show() }
    }

    private var anchor: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private var anchorScreen: NSScreen? {
        if let anchor {
            let point = NSPoint(x: anchor.midX, y: anchor.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return screen }
        }
        return statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func positionPanel() {
        guard let screen = anchorScreen else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let width = min(max(preferredWidth, min(360, bounds.width)), bounds.width)
        let top = min(anchor.map { $0.minY - 4 } ?? bounds.maxY, bounds.maxY)
        let availableHeight = max(1, top - bounds.minY)
        let height = min(StatusPanelLayout.preferredHeight(uploads: model.uploads.fileCount,
                                                          downloads: model.downloads.fileCount), availableHeight)
        let right = anchor?.maxX ?? bounds.maxX
        let x = min(max(right - width, bounds.minX), bounds.maxX - width)
        layingOut = true
        panel.minSize = NSSize(width: min(360, bounds.width), height: height)
        panel.maxSize = NSSize(width: bounds.width, height: height)
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
        layingOut = false
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        var maximumWidth = panel.maxSize.width
        if let screen = anchorScreen {
            let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let resizingLeftEdge = NSEvent.mouseLocation.x < panel.frame.midX
            maximumWidth = min(maximumWidth, resizingLeftEdge
                               ? panel.frame.maxX - bounds.minX : bounds.maxX - panel.frame.minX)
        }
        return NSSize(width: min(max(frameSize.width, panel.minSize.width), maximumWidth),
                      height: panel.frame.height)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !layingOut else { return }
        preferredWidth = panel.frame.width
        if !model.isPreview { Prefs.store.set(preferredWidth, forKey: PrefKey.panelWidth) }
        positionPanel()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    private func installDismissalMonitors() {
        guard localMonitor == nil else { return }
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackingMenus += 1 }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.trackingMenus = max(0, self.trackingMenus - 1)
                }
            },
        ]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let suppress = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown {
                    if event.keyCode == 53 && event.window === self.panel && self.trackingMenus == 0 {
                        self.close()
                        return true
                    }
                    return false
                }
                // Owned menus/windows and the status button remain interactive.
                if event.window != nil { return false }
                self.dismissIfOutside()
                return false
            }
            return suppress ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissIfOutside() }
        }
    }

    private func dismissIfOutside() {
        guard isVisible, !panel.inLiveResize, trackingMenus == 0 else { return }
        let point = NSEvent.mouseLocation
        // Native resize handles extend slightly beyond the visible frame.
        guard !panel.frame.insetBy(dx: -8, dy: -8).contains(point),
              !(anchor?.contains(point) ?? false) else { return }
        close()
    }

    private func removeDismissalMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        menuObservers.removeAll()
        trackingMenus = 0
    }
}

@MainActor
private final class TransferPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
