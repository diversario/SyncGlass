# SyncGlass

SyncGlass shows current iCloud Drive transfers in the macOS menu bar.

**Work in progress.** The current build can miss downloads.

## Transfers

- The icon shows uploads, downloads, or both.
- Click the icon to open the transfer panel.
- Each direction has its own file count and byte summary.
- Each list shows up to ten rows. Scroll to see the remaining files.
- Rows show the filename and its parent folder. Long names lose text at the beginning.
- Hover over a row to see its full path.
- Drag a side of the panel to show more of each filename. The app saves the width.

Byte counts come from progress published by macOS. Some transfers do not publish usable counts. The panel marks those counts as unavailable. A summary marked **Reported** contains only the known bytes. It is not a complete transfer total.

Counts cover files observed in the watched folders. They do not describe transfers on other devices.

## Folder access

The default watched folder is iCloud Drive. SyncGlass also watches Desktop and Documents when macOS identifies them as iCloud folders.

The monitor reads filenames and sync metadata. It does not read file contents. It does not request downloads or remove local downloads.

macOS may ask for access to watched folders. macOS has no separate metadata-only permission. Without access, SyncGlass cannot show complete results for those folders.

Photos, Mail, and other iCloud services are not monitored.

## Settings

Settings keeps the watched-folder choice, path filters, hidden-file and symbolic-link options, download tracking, and manual rescan.

Start at login is opt-in. Optional queue diagnostics run only when enabled.

This fork does not keep transfer history. It has no transfer notifications, folder-size scans, or automatic update checks.

## Resource use

File events wake the monitor. Metadata checks run in bounded batches. Active files are checked again with increasing delays. There is no repeating metadata check when the monitor is idle.

The transfer panel subscribes to byte progress only while open. Subscription count is bounded. Files without a subscription remain in the lists and counts.

Startup and rescans walk folder metadata. A scan can take time on a large drive. A scan does not retain a full file inventory.

## Build and run

Build on macOS with Xcode command-line tools:

```sh
ARCHS=native bin/build-app.sh
open build/SyncGlass.app
```

The local build uses ad-hoc signing. It is not notarized. The login helper is included in the app bundle.

Focused checks:

```sh
swift test --filter 'TransferSummaryTests|MenuBarSymbolTests|TrackerSchedulingTests|ItemStateTests|StartEventIDTests'
```


## Credits

SyncGlass is inspired by [iCloudStatus](http://www.thealchemistguild.com) by The Alchemist Guild, a no longer maintained app for Intel Macs. SyncGlass is a new app and released as an entirely independent project. The app was created with AI assistance (Claude).

## License

[GNU General Public License v3.0](LICENSE)
