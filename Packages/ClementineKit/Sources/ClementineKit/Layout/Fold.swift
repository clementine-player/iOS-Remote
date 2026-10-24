import CoreGraphics

/// A fold that splits a view in two: a foldable half-open like a book, or set down like a laptop.
/// Screens that lay out around it put things on either side of it rather than across it.
public enum Fold: Equatable, Sendable {
    /// Half-open like a book: `leading` is the width on the view's leading side, then the fold.
    case vertical(leading: CGFloat, width: CGFloat)
    /// Set down like a laptop: `above` is the height above the fold, then the fold.
    case horizontal(above: CGFloat, height: CGFloat)

    /// Where a division (such as a hinge) reserves space in a view, in the view's own points, with
    /// left at x = 0 whatever the layout direction.
    public struct Division: Equatable, Sendable {
        public var frame: CGRect
        /// A foldable open flat has an inactive division: it splits nothing.
        public var isActive: Bool

        public init(frame: CGRect, isActive: Bool = true) {
            self.frame = frame
            self.isActive = isActive
        }
    }

    /// The fold that splits a view of `size` from the `divisions` that reach it, if there is one.
    /// A division only splits the view if it crosses it from edge to edge, with the view on both
    /// sides; in right-to-left layouts the leading side is on the right.
    public init?(divisions: [Division], in size: CGSize, rightToLeft: Bool = false) {
        let bounds = CGRect(origin: .zero, size: size)
        for division in divisions where division.isActive {
            let frame = division.frame
            if frame.height > frame.width {
                guard frame.minX > bounds.minX, frame.maxX < bounds.maxX else { continue }
                let leading = rightToLeft ? bounds.maxX - frame.maxX : frame.minX - bounds.minX
                self = .vertical(leading: leading, width: frame.width)
                return
            } else {
                guard frame.minY > bounds.minY, frame.maxY < bounds.maxY else { continue }
                self = .horizontal(above: frame.minY - bounds.minY, height: frame.height)
                return
            }
        }
        return nil
    }
}
