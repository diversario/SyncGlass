import AppKit
import Network
import SwiftUI

@main
enum SyncGlassApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = StatusModel()
    private var tracker: Tracker?
    private var controller: StatusPanelController!
    private let pathMonitor = NWPathMonitor()
    private var defaultsObserver: NSObjectProtocol?
    private var lastSettings: MonitoringSettings?
    private var windows: [String: NSWindow] = [:]
    private var windowObservers: [String: NSObjectProtocol] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--preview") {
            model.isPreview = true
            makeController()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                Preview.show(model: model, controller: controller)
            }
            return
        }
        #endif
        if CommandLine.arguments.contains("--login-item-status") {
            print("login item: \(LoginItem.status.rawValue) (\(LoginItem.statusDescription))")
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--queue-status") {
            printQueueStatus()
            return
        }
        Prefs.registerDefaults()
        makeController()
        let tracker = Tracker(directory: Prefs.folder)
        self.tracker = tracker
        tracker.delegate = self
        lastSettings = MonitoringSettings()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: Prefs.store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor in
                self?.tracker?.networkReachabilityChanged(isReachable: reachable)
                self?.model.setReachable(reachable)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "SyncGlass.reachability"))
        tracker.start()
        model.update(tracker.snapshot())
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.close()
        tracker?.stop()
        pathMonitor.cancel()
        ICloudQueueMonitor.shared.stop()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    private func makeController() {
        controller = StatusPanelController(model: model, onSettings: { [weak self] in self?.showSettings() })
        controller.onFileInfo = { [weak self] path in self?.showFileInfo(path) }
    }

    private func defaultsChanged() {
        let settings = MonitoringSettings()
        guard settings != lastSettings else { return }
        let folderChanged = settings.folder != lastSettings?.folder
        lastSettings = settings
        if folderChanged { tracker?.setDirectory(settings.folder) } else { tracker?.preferencesChanged() }
    }

    private func showSettings() {
        showWindow(key: "settings", title: "SyncGlass Settings", view: SettingsView(),
                   size: NSSize(width: 540, height: 560))
    }

    private func showFileInfo(_ path: String) {
        guard !model.isPreview else { return }
        showWindow(key: path, title: (path as NSString).lastPathComponent,
                   view: FileInfoView(path: path), size: NSSize(width: 480, height: 680))
    }

    private func showWindow<V: View>(key: String, title: String, view: V, size: NSSize) {
        controller.close()
        if let window = windows[key] {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: view)
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        windows[key] = window
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                if self?.windows[key] === window {
                    self?.windows[key] = nil
                    if let observer = self?.windowObservers.removeValue(forKey: key) {
                        NotificationCenter.default.removeObserver(observer)
                    }
                }
            }
        }
        windowObservers[key] = observer
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func printQueueStatus() {
        Task {
            let now = Date()
            let output = await Task.detached { ICloudQueue.readStatus() }.value
            let items = ICloudQueue.parse(output ?? "", now: now)
            for item in items {
                let path = await ICloudQueue.resolve(item) ?? "not found: \(item.folder) \(item.name)"
                print("\(item.state ?? "-"): \(path)")
            }
            NSApp.terminate(nil)
        }
    }
}

extension AppDelegate: TrackerDelegate {
    func trackerStatusChanged(_ snapshot: TrackerSnapshot) { model.update(snapshot) }
}

private struct MonitoringSettings: Equatable {
    let folder = Prefs.folder
    let downloads = Prefs.trackIncomingDownloads
    let hidden = Prefs.ignoreHiddenFiles
    let symlinks = Prefs.ignoreSymbolicLinks
    let polling = Prefs.pollingMode
    let includes = Prefs.includePatterns
    let excludes = Prefs.excludePatterns
}
