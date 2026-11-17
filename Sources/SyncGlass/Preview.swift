#if DEBUG
import AppKit
import Darwin

/// Deterministic synthetic data, displayed through the production status item.
@MainActor
enum Preview {
    static func show(model: StatusModel, controller: StatusPanelController) {
        model.isPreview = true
        switch argument("--preview-appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "contrast": NSApp.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
        default: break
        }
        let mode = argument("--preview-mode") ?? "mixed"
        let count = max(0, Int(argument("--preview-count") ?? "25") ?? 25)
        var items: [TransferItem] = []
        var progress: [String: FileProgress] = [:]
        let directions: [TransferDirection]
        switch mode {
        case "upload", "waiting": directions = [.upload]
        case "download": directions = [.download]
        case "empty": directions = []
        default: directions = [.upload, .download]
        }
        for direction in directions {
            for index in 0..<count {
                let parent = index.isMultiple(of: 2) ? "Project Alpha" : "Project Beta"
                let name = index < 2 ? "Shared filename.pdf" :
                    "A deliberately long filename for verifying leading truncation at the minimum panel width – \(index + 1).bin"
                let path = "/Preview/\(direction.title)/\(parent)/\(name)"
                let waiting = mode == "waiting"
                items.append(TransferItem(path: path, active: waiting ? [] : direction.flag,
                                          waitingUpload: waiting))
                if mode != "unknown" && !waiting {
                    let total: Int64 = 67_108_864
                    let completed = total * Int64((index % 7) + 1) / 10
                    progress[path] = FileProgress(
                        direction: direction == .upload ? .uploading : .downloading,
                        fraction: Double(completed) / Double(total),
                        completedBytes: completed, totalBytes: total)
                }
            }
        }
        model.update(TrackerSnapshot(items: items.sorted { $0.path < $1.path }))
        model.setPreviewProgress(progress)
        controller.refresh()
        controller.show()
        print("READY pid=\(ProcessInfo.processInfo.processIdentifier) window=\(controller.verificationWindowID) frame=\(NSStringFromRect(controller.verificationFrame)) button=\(NSStringFromRect(controller.verificationStatusButtonRect))")
        fflush(stdout)
    }

    private static func argument(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
#endif
