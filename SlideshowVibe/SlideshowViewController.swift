import AppKit
import CoreVideo

final class SlideshowViewController: NSViewController {

    // MARK: Properties

    private let folderURL: URL
    private var gridView: PhotoGridView!
    private var reflectionView: ReflectionView!
    private var displayLink: CVDisplayLink?

    /// Scroll speed in points per second
    private let scrollSpeed: CGFloat = 40
    /// Direction: +1 = scrolling right (offset increases), -1 = scrolling left
    private var scrollDirection: CGFloat = 1
    /// Timestamp of last display link callback
    private var lastTimestamp: CVTimeStamp?

    // MARK: Init

    init(folderURL: URL) {
        self.folderURL = folderURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: View Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        loadImages()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startDisplayLink()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopDisplayLink()
    }

    // MARK: Layout

    private func setupViews() {
        let container = view

        gridView = PhotoGridView(frame: .zero)
        gridView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(gridView)

        reflectionView = ReflectionView(frame: .zero)
        reflectionView.gridView = gridView
        reflectionView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(reflectionView)

        NSLayoutConstraint.activate([
            gridView.topAnchor.constraint(equalTo: container.topAnchor),
            gridView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            gridView.heightAnchor.constraint(equalTo: container.heightAnchor, multiplier: 0.60),

            reflectionView.topAnchor.constraint(equalTo: gridView.bottomAnchor),
            reflectionView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            reflectionView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            reflectionView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // When grid layout changes (images load / window resizes), rebuild reflection layers
        gridView.onLayoutChanged = { [weak self] in
            guard let self = self else { return }
            self.reflectionView.buildLayers(from: self.gridView)
        }

        // When an image finishes loading, update the matching reflection cell too
        gridView.onImageLoaded = { [weak self] idx, cgImage in
            self?.reflectionView.updateCellImage(at: idx, cgImage: cgImage)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        gridView.recomputeLayouts()
        // onLayoutChanged fires from recomputeLayouts and rebuilds the reflection
    }

    // MARK: Image Loading

    private func loadImages() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let urls = ImageLoader.shared.collectImageURLs(in: self.folderURL)
            DispatchQueue.main.async {
                if urls.isEmpty {
                    self.showNoImagesAlert()
                } else {
                    self.gridView.setImageURLs(urls)
                }
            }
        }
    }

    private func showNoImagesAlert() {
        let alert = NSAlert()
        alert.messageText = "No Images Found"
        alert.informativeText = "No supported image files were found in the selected folder."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: CVDisplayLink

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        var optLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&optLink)
        guard let link = optLink else { return }

        let callback: CVDisplayLinkOutputCallback = { (_, inNow, _, _, _, userInfo) -> CVReturn in
            let vc = Unmanaged<SlideshowViewController>.fromOpaque(userInfo!).takeUnretainedValue()
            vc.displayLinkFired(timestamp: inNow.pointee)
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        self.displayLink = link
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
    }

    private func displayLinkFired(timestamp: CVTimeStamp) {
        let dt: CGFloat
        if let last = lastTimestamp {
            let elapsed = CGFloat(timestamp.hostTime &- last.hostTime) / CGFloat(1_000_000_000)
            dt = min(elapsed, 0.1)
        } else {
            dt = 1.0 / 60.0
        }
        lastTimestamp = timestamp

        DispatchQueue.main.async { [weak self] in
            self?.updateScroll(dt: dt)
        }
    }

    private func updateScroll(dt: CGFloat) {
        let maxOffset = gridView.maxScrollOffset
        guard maxOffset > 0 else { return }

        var offset = gridView.scrollOffset
        offset += scrollSpeed * scrollDirection * dt

        if scrollDirection > 0 && offset >= maxOffset {
            offset = maxOffset
            scrollDirection = -1
        } else if scrollDirection < 0 && offset <= 0 {
            offset = 0
            scrollDirection = 1
        }

        // Both updates are CATransaction position changes — GPU composited at vsync,
        // no software redraw triggered.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridView.scrollOffset = offset
        reflectionView.updateScrollOffset(offset)
        CATransaction.commit()

        gridView.prefetchAround(offset: offset)
    }
}
