import AppKit
import CoreGraphics

/// Renders a vertically-flipped, gradient-faded reflection of the photo grid using CALayers.
/// Each cell layer shares the same CGImage data as the grid — no extra copies in GPU memory.
final class ReflectionView: NSView {

    weak var gridView: PhotoGridView?

    private let scrollContainerLayer = CALayer()
    private var rowLayersList: [CALayer] = []
    private(set) var cellLayerMap: [Int: CALayer] = [:]

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
        setupGradientMask()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Gradient Mask

    private func setupGradientMask() {
        let mask = CAGradientLayer()
        // y=1 is top in CALayer coords; fade from semi-opaque at top to clear at bottom
        mask.colors = [NSColor(white: 1, alpha: 0.6).cgColor,
                       NSColor(white: 1, alpha: 0.0).cgColor]
        mask.startPoint = CGPoint(x: 0.5, y: 1.0)
        mask.endPoint   = CGPoint(x: 0.5, y: 0.0)
        layer?.mask = mask
    }

    override func layout() {
        super.layout()
        layer?.mask?.frame = layer?.bounds ?? .zero
        guard let grid = gridView, !grid.rowLayouts.isEmpty, bounds.height > 0 else { return }
        buildLayers(from: grid)
    }

    // MARK: Layer Management

    /// Rebuild all reflection cell layers from the current grid state.
    /// Called whenever the grid layout changes or this view is resized.
    func buildLayers(from grid: PhotoGridView) {
        guard bounds.height > 0, grid.bounds.height > 0, !grid.rowLayouts.isEmpty else { return }

        scrollContainerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        rowLayersList.removeAll()
        cellLayerMap.removeAll()

        let rowCount = PhotoGridView.rowCount
        let gridH = grid.bounds.height
        let gap = PhotoGridView.gap
        // Match the grid's row height exactly (gap-aware), no vertical squashing.
        let rh = (gridH - CGFloat(rowCount - 1) * gap) / CGFloat(rowCount)
        let contentWidth = grid.rowLayouts.map { $0.totalWidth }.max() ?? 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        scrollContainerLayer.frame = CGRect(x: -grid.scrollOffset, y: 0,
                                            width: contentWidth, height: bounds.height)

        for row in 0..<rowCount {
            guard row < grid.rowLayouts.count else { continue }
            let layout = grid.rowLayouts[row]

            let rowLayer = CALayer()
            rowLayer.anchorPoint = .zero
            rowLayer.isOpaque = true
            rowLayer.backgroundColor = NSColor.black.cgColor
            // Anchor rows from the top of the reflection view downward.
            // row 2 (bottom of grid) → top of reflection; row 0 → may clip at bottom.
            // Anchor from top: row 2 (bottom of grid) at top of reflection, with matching gaps.
            let rowY = bounds.height - CGFloat(rowCount - row) * (rh + gap) + gap
            rowLayer.frame = CGRect(x: 0, y: rowY, width: layout.totalWidth, height: rh)
            scrollContainerLayer.addSublayer(rowLayer)
            rowLayersList.append(rowLayer)

            for cell in layout.cells {
                let cellLayer = CALayer()
                // anchorPoint at center so CATransform3D scale flips about the cell's midpoint
                cellLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                cellLayer.contentsGravity = .resize
                // Flip image vertically to create the reflection effect
                cellLayer.transform = CATransform3DMakeScale(1, -1, 1)

                let item = grid.photoItems[cell.itemIndex]
                if let cgImg = item.cgImage {
                    cellLayer.contents = cgImg
                } else {
                    cellLayer.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
                }

                // Use position+bounds (not frame) because the layer has a transform applied
                cellLayer.position = CGPoint(x: cell.x + cell.width / 2, y: rh / 2)
                cellLayer.bounds = CGRect(x: 0, y: 0, width: cell.width, height: rh)

                rowLayer.addSublayer(cellLayer)
                cellLayerMap[cell.itemIndex] = cellLayer
            }
        }

        CATransaction.commit()
    }

    /// Shift the reflection scroll position to match the grid.
    func updateScrollOffset(_ offset: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var f = scrollContainerLayer.frame
        f.origin.x = -offset
        scrollContainerLayer.frame = f
        CATransaction.commit()
    }

    /// Update a single cell's image after it finishes loading.
    func updateCellImage(at index: Int, cgImage: CGImage) {
        guard let cellLayer = cellLayerMap[index] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cellLayer.contents = cgImage
        cellLayer.backgroundColor = nil
        CATransaction.commit()
    }
}
