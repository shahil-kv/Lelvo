import Foundation
import Testing
import LelvoCore

@Suite struct SwipeSelectionTests {
    private let order = (0..<20).map { "p\($0)" }

    @Test func startingOnAnUnselectedTileSelectsIt() {
        let s = SwipeSelection(order: order, anchor: 3, selection: [])
        #expect(s.selecting)
        #expect(s.selection == ["p3"])
    }

    @Test func startingOnASelectedTileDeselectsIt() {
        let s = SwipeSelection(order: order, anchor: 3, selection: ["p3", "p9"])
        #expect(!s.selecting)
        #expect(s.selection == ["p9"])
    }

    /// A jump over whole rows (fast finger, auto-scroll) still takes every tile between, not only the one under the finger.
    @Test func movingFillsEveryTileBetweenAnchorAndFinger() {
        var s = SwipeSelection(order: order, anchor: 2, selection: [])
        let changed = s.move(to: 6)
        #expect(s.selection == ["p2", "p3", "p4", "p5", "p6"])
        #expect(Set(changed) == ["p3", "p4", "p5", "p6"])
    }

    @Test func movingUpSelectsBackwardsFromTheAnchor() {
        var s = SwipeSelection(order: order, anchor: 5, selection: [])
        s.move(to: 3)
        #expect(s.selection == ["p3", "p4", "p5"])
    }

    @Test func movingBackRestoresWhatTheTilesWereBefore() {
        var s = SwipeSelection(order: order, anchor: 2, selection: ["p5"])
        s.move(to: 7)
        let changed = s.move(to: 3)
        #expect(s.selection == ["p2", "p3", "p5"], "p5 was selected before the swipe and stays; p4, p6, p7 go back")
        #expect(Set(changed) == ["p4", "p6", "p7"])
    }

    @Test func crossingTheAnchorSwapsSides() {
        var s = SwipeSelection(order: order, anchor: 5, selection: [])
        s.move(to: 8)
        s.move(to: 3)
        #expect(s.selection == ["p3", "p4", "p5"])
    }

    @Test func deselectingKeepsTilesOutsideTheRange() {
        var s = SwipeSelection(order: order, anchor: 2, selection: ["p1", "p2", "p3", "p4", "p8"])
        s.move(to: 3)
        #expect(s.selection == ["p1", "p4", "p8"])
        s.move(to: 2)
        #expect(s.selection == ["p1", "p3", "p4", "p8"])
    }

    @Test func stayingOnTheSameTileChangesNothing() {
        var s = SwipeSelection(order: order, anchor: 2, selection: [])
        s.move(to: 4)
        #expect(s.move(to: 4).isEmpty)
    }

    @Test func tilesThatAlreadyMatchAreNotReportedAsChanged() {
        var s = SwipeSelection(order: order, anchor: 2, selection: ["p3"])
        #expect(s.move(to: 4) == ["p4"], "p3 was already selected, so its tile needs no redraw")
    }

    @Test func positionOutsideTheLibraryIsClamped() {
        var s = SwipeSelection(order: order, anchor: 18, selection: [])
        s.move(to: 500)
        #expect(s.selection == ["p18", "p19"])
    }

    // MARK: Auto-scroll

    @Test func noAutoScrollAwayFromTheEdges() {
        #expect(SwipeSelection.autoScrollSpeed(fingerY: 400, top: 100, bottom: 800) == 0)
    }

    @Test func autoScrollDirectionFollowsTheEdge() {
        #expect(SwipeSelection.autoScrollSpeed(fingerY: 110, top: 100, bottom: 800) < 0)
        #expect(SwipeSelection.autoScrollSpeed(fingerY: 790, top: 100, bottom: 800) > 0)
    }

    @Test func autoScrollGetsFasterNearerTheEdge() {
        let near = SwipeSelection.autoScrollSpeed(fingerY: 780, top: 100, bottom: 800)
        let nearer = SwipeSelection.autoScrollSpeed(fingerY: 795, top: 100, bottom: 800)
        #expect(nearer > near)
    }

    @Test func autoScrollSpeedIsCappedPastTheEdge() {
        let atEdge = SwipeSelection.autoScrollSpeed(fingerY: 800, top: 100, bottom: 800)
        #expect(SwipeSelection.autoScrollSpeed(fingerY: 900, top: 100, bottom: 800) == atEdge)
        #expect(SwipeSelection.autoScrollSpeed(fingerY: 0, top: 100, bottom: 800) == -atEdge)
    }
}
