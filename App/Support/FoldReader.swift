import ClementineKit
import SwiftUI

extension GeometryProxy {
    /// The fold that splits this view in two, on a foldable half-open like a book or set down like
    /// a laptop; nil open flat, closed, and on every other device. `size` is the view's size, if
    /// it's laid out as larger than it is (to keep its layout while the keyboard is open).
    func fold(layoutDirection: LayoutDirection, size: CGSize? = nil) -> Fold? {
        guard #available(iOS 27.1, *) else { return nil }
        // Unmirrored, so a fold is measured from the left whatever the layout direction, as Fold
        // expects.
        let divisions = reservedRegions(kind: .division, layoutDirectionBehavior: .fixed)
            .map { Fold.Division(frame: $0.frame, isActive: $0.isActive) }
        return Fold(divisions: divisions, in: size ?? self.size, rightToLeft: layoutDirection == .rightToLeft)
    }
}

