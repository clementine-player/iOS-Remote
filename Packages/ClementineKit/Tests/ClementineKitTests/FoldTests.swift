import CoreGraphics
import Testing
@testable import ClementineKit

/// Screens lay out around a fold only when it splits them, measured from their own edges.
struct FoldTests {
    // A book-style foldable's inner screen, in points, with the player below a top row.
    let player = CGSize(width: 1000, height: 750)

    func fold(_ divisions: Fold.Division..., rightToLeft: Bool = false) -> Fold? {
        Fold(divisions: divisions, in: player, rightToLeft: rightToLeft)
    }

    @Test func noFoldOnAnOrdinaryPhone() {
        #expect(fold() == nil)
    }

    @Test func aFoldOpenFlatSplitsNothing() {
        #expect(fold(.init(frame: CGRect(x: 500, y: 0, width: 0, height: 750), isActive: false)) == nil)
    }

    @Test func halfOpenLikeABook() {
        #expect(fold(.init(frame: CGRect(x: 500, y: 0, width: 0, height: 750))) == .vertical(leading: 500, width: 0))
    }

    @Test func theLeadingSideIsOnTheRightInRightToLeft() {
        let fold = fold(.init(frame: CGRect(x: 400, y: 0, width: 20, height: 750)), rightToLeft: true)
        #expect(fold == .vertical(leading: 580, width: 20))
    }

    @Test func setDownLikeALaptop() {
        #expect(fold(.init(frame: CGRect(x: 0, y: 350, width: 1000, height: 0))) == .horizontal(above: 350, height: 0))
    }

    @Test func aFoldOutsideTheViewIsIgnored() {
        // Above the player, in its top row.
        #expect(fold(.init(frame: CGRect(x: 0, y: -50, width: 1000, height: 0))) == nil)
    }

    @Test func aFoldAtTheViewsEdgeIsIgnored() {
        // A pane beside the fold in Split View: the fold is the pane's edge, so nothing is split.
        #expect(fold(.init(frame: CGRect(x: 1000, y: 0, width: 20, height: 750))) == nil)
    }
}
