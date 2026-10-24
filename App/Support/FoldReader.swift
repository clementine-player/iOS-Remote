import ClementineKit
import SwiftUI

extension GeometryProxy {
    /// The fold that splits this view in two, on a foldable half-open like a book or set down like
    /// a laptop; nil open flat, closed, and on every other device. `size` is the view's size, if
    /// it's laid out as larger than it is (to keep its layout while the keyboard is open).
    func fold(layoutDirection: LayoutDirection, size: CGSize? = nil) -> Fold? {
        let size = size ?? self.size
        let rightToLeft = layoutDirection == .rightToLeft
        if let fake = FakeFold.current {
            return Fold(divisions: [fake.division(in: size)], in: size, rightToLeft: rightToLeft)
        }
        guard #available(iOS 27.1, *) else { return nil }
        // Unmirrored, so a fold is measured from the left whatever the layout direction, as Fold
        // expects.
        let divisions = reservedRegions(kind: .division, layoutDirectionBehavior: .fixed)
            .map { Fold.Division(frame: $0.frame, isActive: $0.isActive) }
        return Fold(divisions: divisions, in: size, rightToLeft: rightToLeft)
    }
}

/// A fold through the middle of every view, for the screenshots (UITests/Screenshots.swift),
/// which can't pose a foldable: launched with `-fake_fold horizontal` or `-fake_fold vertical`.
private enum FakeFold: String {
    case horizontal, vertical

    static let current = UserDefaults.standard.string(forKey: "fake_fold").flatMap(FakeFold.init)

    func division(in size: CGSize) -> Fold.Division {
        switch self {
        case .horizontal: Fold.Division(frame: CGRect(x: 0, y: size.height / 2, width: size.width, height: 0))
        case .vertical: Fold.Division(frame: CGRect(x: size.width / 2, y: 0, width: 0, height: size.height))
        }
    }
}
