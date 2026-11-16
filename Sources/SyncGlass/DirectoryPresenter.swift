import Foundation

/// File coordination reports changes inside nested directories.
final class DirectoryPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    private static let attributes: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
        .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey,
    ]

    private let directory: URL
    private let changed: @Sendable (URL) -> Void
    var presentedItemURL: URL? { directory }
    let presentedItemOperationQueue: OperationQueue
    var observedPresentedItemUbiquityAttributes: Set<URLResourceKey> { Self.attributes }

    init(directory: URL, queue: OperationQueue, changed: @escaping @Sendable (URL) -> Void) {
        self.directory = directory
        self.presentedItemOperationQueue = queue
        self.changed = changed
        super.init()
    }

    func presentedItemDidChange() { changed(directory) }
    func presentedItemDidChangeUbiquityAttributes(_ attributes: Set<URLResourceKey>) { changed(directory) }
    func presentedSubitemDidAppear(at url: URL) { changed(url) }
    func presentedSubitemDidChange(at url: URL) { changed(url) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        changed(oldURL)
        changed(newURL)
    }
}
