import AppKit
import CoreVideo

final class SlideshowViewController: NSViewController {

    // MARK: Properties

    private let folderURL: URL
    private var gridView: PhotoGridView!
    private var reflectionView: ReflectionView!
    private var displayLink: CVDisplayLink?

    private let config = Config.load()

    /// Scroll speed in points per second
    private var scrollSpeed: CGFloat { CGFloat(config.scrollSpeed) }
    /// Direction: +1 = scrolling right (offset increases), -1 = scrolling left
    private var scrollDirection: CGFloat = 1
    /// Timestamp of last display link callback
    private var lastTimestamp: CVTimeStamp?
    /// Limits the display link to one pending scroll update on the main queue at a time.
    /// If the main thread is still processing a previous update when the next tick fires,
    /// that tick is dropped rather than queued, preventing position double-steps.
    private let scrollSemaphore = DispatchSemaphore(value: 1)

    /// Width constraints updated by applyTiltTransform so the views are physically wider
    /// than the window — perspective then compresses the extra content into the visible area,
    /// filling the right-side gap without stretching any images.
    private var gridWidthConstraint: NSLayoutConstraint!
    private var reflectionWidthConstraint: NSLayoutConstraint!

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

        // Width starts at the window width; applyTiltTransform widens it so perspective
        // compression fills the gap on the right without scaling/stretching images.
        gridWidthConstraint      = gridView.widthAnchor.constraint(equalToConstant: container.bounds.width)
        reflectionWidthConstraint = reflectionView.widthAnchor.constraint(equalToConstant: container.bounds.width)

        NSLayoutConstraint.activate([
            gridView.topAnchor.constraint(equalTo: container.topAnchor),
            gridView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gridWidthConstraint,
            gridView.heightAnchor.constraint(equalTo: container.heightAnchor, multiplier: 0.60),

            reflectionView.topAnchor.constraint(equalTo: gridView.bottomAnchor, constant: PhotoGridView.gap),
            reflectionView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            reflectionWidthConstraint,
            reflectionView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // When grid layout changes (images load / window resizes), rebuild reflection layers
        gridView.onLayoutChanged = { [weak self] in
            guard let self = self else { return }
            // Only do a full rebuild when cells were added/removed.
            // For aspect-ratio-driven relayouts (very common during image loading),
            // just reposition existing layers — avoids destroying/recreating hundreds of layers.
            if self.reflectionView.cellLayerMap.count == self.gridView.photoItems.count {
                self.reflectionView.updateCellFrames(from: self.gridView)
            } else {
                self.reflectionView.buildLayers(from: self.gridView)
            }
        }

        // When an image finishes loading, update the matching reflection cell too
        gridView.onImageLoaded = { [weak self] idx, cgImage in
            self?.reflectionView.updateCellImage(at: idx, cgImage: cgImage)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        gridView.recomputeLayouts()
        applyTiltTransform()
        // onLayoutChanged fires from recomputeLayouts and rebuilds the reflection
    }

    /// Applies a Y-axis tilt with perspective to the container's sublayerTransform.
    /// Rather than scaling the transform (which stretches images), the grid and reflection
    /// views are made physically wider than the window. Perspective then compresses the
    /// extra content into the visible area — images keep their correct proportions.
    private func applyTiltTransform() {
        guard config.gridTiltAngle != 0 else { return }
        let angle = CGFloat(config.gridTiltAngle) * .pi / 180
        let D: CGFloat = 1200          // perspective distance (points)
        let W = view.bounds.width
        guard W > 0 else { return }

        // The right edge of the content (at x = contentWidth) must project to x = W.
        // Solving: contentWidth·cos(θ)/(1 + contentWidth·sin(θ)/D) = W
        // → contentWidth = W / (cos(θ) − W·sin(θ)/D)
        let denom = cos(angle) - W * sin(angle) / D
        guard denom > 0 else { return }
        let contentWidth = W / denom   // wider than W; no image scaling involved

        gridWidthConstraint.constant      = contentWidth
        reflectionWidthConstraint.constant = contentWidth

        // Pure perspective + rotation — no X scale, so images are never stretched.
        var t = CATransform3DIdentity
        t.m34 = -1.0 / D
        t = CATransform3DRotate(t, angle, 0, 1, 0)

        // Shift the perspective's y-vanishing line to the visual bottom of the grid so the
        // bottom row appears horizontal. Without this, depth varies as z = −x·sin(θ), making
        // y_proj = y/(1 + x·sin(θ)/D) tilt toward y=0 (container bottom) as x increases.
        // Adding vpY·sin(θ)/D to m12 (the x→y cross-term) shifts the neutral line to vpY:
        //   y_proj = (y − vpY)/w + vpY  for all x along the bottom row. ✓
        let vpY = gridView.frame.minY
        t.m12 += vpY * sin(angle) / D

        view.layer?.sublayerTransform = t
    }

    // MARK: Image Loading

    private func loadImages() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let all  = ImageLoader.shared.collectImageURLs(in: self.folderURL)
            let urls = Array(all.shuffled().prefix(self.config.maxImages))
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

        guard scrollSemaphore.wait(timeout: .now()) == .success else { return }
        DispatchQueue.main.async { [weak self] in
            defer { self?.scrollSemaphore.signal() }
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
