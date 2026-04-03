import AppKit
import CoreGraphics

// MARK: - Photo Item

struct PhotoItem {
    let url: URL
    var image: NSImage?
    var cgImage: CGImage?
    var aspectRatio: CGFloat  // width/height; placeholder until image loads
}

// MARK: - Row Layout

struct RowLayout {
    struct Cell {
        let itemIndex: Int
        let x: CGFloat
        let width: CGFloat
    }
    let cells: [Cell]
    let totalWidth: CGFloat
}

// MARK: - PhotoGridView

/// Renders three rows of photos using CALayer sublayers.
/// Scrolling is a single layer position update — no per-frame CPU draw.
final class PhotoGridView: NSView {

    // MARK: Configuration
    static let rowCount = 3
    static let gap: CGFloat = 8
    static let placeholderAspect: CGFloat = 1.5

    // MARK: Callbacks
    var onLayoutChanged: (() -> Void)?
    var onImageLoaded: ((Int, CGImage) -> Void)?

    // MARK: State
    private(set) var photoItems: [PhotoItem] = []
    private var rowIndices: [[Int]] = [[], [], []]
    var rowLayouts: [RowLayout] = []
    private(set) var maxScrollOffset: CGFloat = 0

    // MARK: Layer hierarchy
    //   layer (view backing layer)
    //   └── scrollContainerLayer  (x = -scrollOffset)
    //         ├── rowLayer[0]
    //         │     ├── cellLayer (item 0)
    //         │     └── cellLayer (item 3) …
    //         ├── rowLayer[1]
    //         └── rowLayer[2]
    private let scrollContainerLayer = CALayer()
    private var rowLayersList: [CALayer] = []
    private(set) var cellLayerMap: [Int: CALayer] = [:]

    // MARK: Scroll

    var scrollOffset: CGFloat = 0 {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var f = scrollContainerLayer.frame
            f.origin.x = -scrollOffset
            scrollContainerLayer.frame = f
            CATransaction.commit()
        }
    }

    private var rowHeight: CGFloat {
        let totalGaps = CGFloat(PhotoGridView.rowCount - 1) * PhotoGridView.gap
        return (bounds.height - totalGaps) / CGFloat(PhotoGridView.rowCount)
    }

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = true
        scrollContainerLayer.anchorPoint = .zero
        scrollContainerLayer.isOpaque = true
        scrollContainerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(scrollContainerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Public API

    func setImageURLs(_ urls: [URL]) {
        photoItems = urls.map { PhotoItem(url: $0, image: nil, cgImage: nil, aspectRatio: PhotoGridView.placeholderAspect) }
        rebuildRowIndices()
        rebuildCellLayers()
        recomputeLayouts()
        startLoadingVisible()
    }

    func imageDidLoad(url: URL, image: NSImage) {
        guard let idx = photoItems.firstIndex(where: { $0.url == url }) else { return }
        let size = image.size
        let aspect = size.width > 0 && size.height > 0 ? size.width / size.height : PhotoGridView.placeholderAspect
        let oldAspect = photoItems[idx].aspectRatio
        let cgImg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        photoItems[idx].image = image
        photoItems[idx].cgImage = cgImg
        photoItems[idx].aspectRatio = aspect

        if let cgImg = cgImg {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let cellLayer = cellLayerMap[idx] {
                cellLayer.contents = cgImg
                cellLayer.backgroundColor = nil
            }
            CATransaction.commit()
            onImageLoaded?(idx, cgImg)
        }

        if abs(oldAspect - aspect) > 0.001 {
            recomputeLayouts()
        }
    }

    // MARK: Layout

    private func rebuildRowIndices() {
        rowIndices = [[], [], []]
        for i in 0..<photoItems.count {
            rowIndices[i % PhotoGridView.rowCount].append(i)
        }
    }

    private func rebuildCellLayers() {
        scrollContainerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        rowLayersList.removeAll()
        cellLayerMap.removeAll()

        for row in 0..<PhotoGridView.rowCount {
            let rowLayer = CALayer()
            rowLayer.anchorPoint = .zero
            rowLayer.isOpaque = true
            rowLayer.backgroundColor = NSColor.black.cgColor
            scrollContainerLayer.addSublayer(rowLayer)
            rowLayersList.append(rowLayer)

            for idx in rowIndices[row] {
                let cellLayer = CALayer()
                cellLayer.anchorPoint = .zero
                cellLayer.contentsGravity = .resize
                cellLayer.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
                rowLayer.addSublayer(cellLayer)
                cellLayerMap[idx] = cellLayer
            }
        }
    }

    func recomputeLayouts() {
        guard bounds.height > 0 else { return }
        let rh = rowHeight
        var layouts: [RowLayout] = []

        for row in 0..<PhotoGridView.rowCount {
            let indices = rowIndices[row]
            var cells: [RowLayout.Cell] = []
            var x: CGFloat = 0
            for idx in indices {
                let aspect = photoItems[idx].aspectRatio
                let w = rh * aspect
                cells.append(RowLayout.Cell(itemIndex: idx, x: x, width: w))
                x += w + PhotoGridView.gap
            }
            let total = max(0, x - PhotoGridView.gap)
            layouts.append(RowLayout(cells: cells, totalWidth: total))
        }
        rowLayouts = layouts

        let maxRowWidth = layouts.map { $0.totalWidth }.max() ?? 0
        maxScrollOffset = max(0, maxRowWidth - bounds.width)

        updateLayerFrames(rh: rh, layouts: layouts)
        onLayoutChanged?()
    }

    private func updateLayerFrames(rh: CGFloat, layouts: [RowLayout]) {
        guard rowLayersList.count == PhotoGridView.rowCount else { return }
        let contentWidth = layouts.map { $0.totalWidth }.max() ?? bounds.width

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        scrollContainerLayer.frame = CGRect(x: -scrollOffset, y: 0,
                                            width: contentWidth, height: bounds.height)

        for row in 0..<PhotoGridView.rowCount {
            let rowLayer = rowLayersList[row]
            let layout = layouts[row]
            // Row 0 is topmost visually → highest y in non-flipped AppKit/CALayer coords
            let rowY = CGFloat(PhotoGridView.rowCount - 1 - row) * (rh + PhotoGridView.gap)
            rowLayer.frame = CGRect(x: 0, y: rowY, width: layout.totalWidth, height: rh)

            for cell in layout.cells {
                if let cellLayer = cellLayerMap[cell.itemIndex] {
                    cellLayer.frame = CGRect(x: cell.x, y: 0, width: cell.width, height: rh)
                }
            }
        }

        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        recomputeLayouts()
    }

    // MARK: Progressive Loading

    func startLoadingVisible() {
        for (i, item) in photoItems.enumerated() {
            let priority: Operation.QueuePriority = i < 30 ? .high : (i < 60 ? .normal : .low)
            ImageLoader.shared.loadThumbnail(url: item.url, priority: priority) { [weak self] url, image in
                guard let self = self, let image = image else { return }
                self.imageDidLoad(url: url, image: image)
            }
        }
    }

    func prefetchAround(offset: CGFloat) {
        guard bounds.width > 0 else { return }
        let prefetchAhead = bounds.width * 2
        for row in 0..<PhotoGridView.rowCount {
            guard row < rowLayouts.count else { continue }
            let layout = rowLayouts[row]
            for cell in layout.cells {
                let cellX = cell.x - offset
                if cellX > -prefetchAhead && cellX < bounds.width + prefetchAhead {
                    let item = photoItems[cell.itemIndex]
                    if item.image == nil {
                        ImageLoader.shared.prefetch(url: item.url)
                    }
                }
            }
        }
    }
}
