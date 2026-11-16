/// The manual action uses the same watched roots, cancellation, and bounded
/// discovery pipeline as startup and FSEvents recovery.
@MainActor
enum Scanner {
    static func scanWithPanel() {
        Tracker.shared?.requestScan()
    }
}
