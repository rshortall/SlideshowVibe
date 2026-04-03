import AppKit
import CoreGraphics
import ImageIO

/// Loads image thumbnails asynchronously using CGImageSource.
final class ImageLoader {

    static let shared = ImageLoader()

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.slideshowvibe.imageloader"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    private var cache: [URL: NSImage] = [:]
    private let cacheLock = NSLock()

    private init() {}

    /// Scan a folder and all subfolders for supported image files.
    func collectImageURLs(in folderURL: URL) -> [URL] {
        let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]
        var results: [URL] = []

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return results }

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if supportedExtensions.contains(ext) {
                results.append(url)
            }
        }
        return results
    }

    /// Load a thumbnail asynchronously. Calls completion on main thread.
    func loadThumbnail(
        url: URL,
        maxPixelSize: Int = 1200,
        priority: Operation.QueuePriority = .normal,
        completion: @escaping (URL, NSImage?) -> Void
    ) {
        // Check cache first
        cacheLock.lock()
        if let cached = cache[url] {
            cacheLock.unlock()
            DispatchQueue.main.async { completion(url, cached) }
            return
        }
        cacheLock.unlock()

        let op = BlockOperation {
            let image = self.loadImageSync(url: url, maxPixelSize: maxPixelSize)
            if let image = image {
                self.cacheLock.lock()
                self.cache[url] = image
                self.cacheLock.unlock()
            }
            DispatchQueue.main.async { completion(url, image) }
        }
        op.queuePriority = priority
        queue.addOperation(op)
    }

    /// Prefetch without callback.
    func prefetch(url: URL, maxPixelSize: Int = 1200) {
        cacheLock.lock()
        let alreadyCached = cache[url] != nil
        cacheLock.unlock()
        if alreadyCached { return }

        loadThumbnail(url: url, maxPixelSize: maxPixelSize, priority: .low) { _, _ in }
    }

    func cachedImage(for url: URL) -> NSImage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[url]
    }

    private func loadImageSync(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
