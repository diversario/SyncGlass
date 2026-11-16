import Foundation

/// User-defaults keys.
enum PrefKey {
    static let iCloudDriveFolder = "ICloudDriveFolder"
    static let pollingMode = "PollingMode"
    static let ignoreHiddenFiles = "IgnoreHiddenFiles"
    static let ignoreSymbolicLinks = "IgnoreSymbolicLinks"
    static let trackIncomingDownloads = "TrackIncomingDownloads"
    static let includePatterns = "IncludePatterns"
    static let excludePatterns = "ExcludePatterns"
    static let launchedFirstTime = "launchedFirstTime"
    /// The ID of the last FSEvents event the tracker received (`Tracker.startEventID`).
    static let lastEventID = "LastFSEventID"
    static let panelWidth = "PanelWidth"
}

/// How many paths in flight are re-checked per pass. Settings offers
/// Moderate ("Frequently") and Economical; 2 is not offered in the UI.
enum PollingMode: Int {
    case moderate = 0
    case economical = 1
    case aggressive = 2

    var batchSize: Int {
        switch self {
        case .moderate: return 100
        case .economical: return 25
        case .aggressive: return 200
        }
    }
}

enum Paths {
    static let mobileDocuments = NSString(string: "~/Library/Mobile Documents").expandingTildeInPath
    static let iCloudDrive = NSString(string: "~/Library/Mobile Documents/com~apple~CloudDocs").expandingTildeInPath

    /// The app's data folder, named after the bundle identifier. The original
    /// iCloudStatus by The Alchemist Guild uses `Application Support/iCloudStatus`;
    /// this app must not read or write that folder.
    static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("io.alberti42.SyncGlass", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

enum Prefs {
    static let store = UserDefaults.standard

    static let defaultIncludePatterns = defaultIncludePatterns(home: NSHomeDirectory())

    /// With Desktop & Documents in iCloud, `~/Desktop` and `~/Documents` stay real
    /// folders and iCloud Drive holds symlinks to them, so FSEvents reports their
    /// files under the home folder, not under `Mobile Documents`.
    static func defaultIncludePatterns(home: String) -> [String] {
        [
            #"\/Mobile\s+Documents\/com~apple~CloudDocs"#,
            #"\/Mobile\s+Documents\/.*\/Documents"#,
            #"\/Mobile\s+Documents\/.*\/CloudStore"#,
            "^" + NSRegularExpression.escapedPattern(for: home) + "/(Desktop|Documents)/",
        ]
    }

    /// Default values. Registered defaults apply until the user changes a setting.
    static func registerDefaults() {
        store.register(defaults: [
            PrefKey.iCloudDriveFolder: Paths.iCloudDrive,
            PrefKey.includePatterns: defaultIncludePatterns,
            PrefKey.excludePatterns: [String](),
            PrefKey.pollingMode: PollingMode.economical.rawValue,
            PrefKey.ignoreHiddenFiles: true,
            PrefKey.ignoreSymbolicLinks: true,
            PrefKey.trackIncomingDownloads: true,
            PrefKey.panelWidth: 520.0,
        ])
    }

    static var folder: String {
        NSString(string: store.string(forKey: PrefKey.iCloudDriveFolder) ?? Paths.iCloudDrive).expandingTildeInPath
    }

    static var includePatterns: [String] { store.stringArray(forKey: PrefKey.includePatterns) ?? [] }
    static var excludePatterns: [String] { store.stringArray(forKey: PrefKey.excludePatterns) ?? [] }
    static var trackIncomingDownloads: Bool { store.bool(forKey: PrefKey.trackIncomingDownloads) }
    static var ignoreHiddenFiles: Bool { store.bool(forKey: PrefKey.ignoreHiddenFiles) }
    static var ignoreSymbolicLinks: Bool { store.bool(forKey: PrefKey.ignoreSymbolicLinks) }
    static var pollingMode: PollingMode { PollingMode(rawValue: store.integer(forKey: PrefKey.pollingMode)) ?? .economical }
}
