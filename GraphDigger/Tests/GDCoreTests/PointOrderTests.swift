import XCTest
@testable import GDCore

/// Order is not cosmetic — consecutive points define the polyline — so these
/// pin the behaviour a wrongly-ordered curve would otherwise hide.
final class PointOrderTests: XCTestCase {

    private let scattered = [
        PixelPoint(x: 300, y: 10),
        PixelPoint(x: 100, y: 30),
        PixelPoint(x: 200, y: 20),
        PixelPoint(x: 200, y: 25),
    ]

    func testExtractionOrderIsUntouched() {
        XCTAssertEqual(PointOrder.extraction.apply(to: scattered), scattered)
    }

    func testAscendingXSortsLeftToRight() {
        XCTAssertEqual(PointOrder.ascendingX.apply(to: scattered).map(\.x),
                       [100, 200, 200, 300])
    }

    func testDescendingXSortsRightToLeft() {
        XCTAssertEqual(PointOrder.descendingX.apply(to: scattered).map(\.x),
                       [300, 200, 200, 100])
    }

    func testReversedWalksTheSequenceBackwards() {
        XCTAssertEqual(PointOrder.reversed.apply(to: scattered).map(\.x),
                       [200, 200, 100, 300])
    }

    /// A vertical run of points shares an x; sorting must not shuffle it, or the
    /// segment would zig-zag up and down instead of running straight.
    func testSortingIsStableOnTies() {
        let ascending = PointOrder.ascendingX.apply(to: scattered)
        XCTAssertEqual(ascending.filter { $0.x == 200 }.map(\.y), [20, 25])

        let descending = PointOrder.descendingX.apply(to: scattered)
        XCTAssertEqual(descending.filter { $0.x == 200 }.map(\.y), [20, 25])
    }

    func testEmptyAndSinglePointInputsAreSafe() {
        XCTAssertTrue(PointOrder.ascendingX.apply(to: []).isEmpty)
        let one = [PixelPoint(x: 5, y: 5)]
        XCTAssertEqual(PointOrder.ascendingX.apply(to: one), one)
        XCTAssertEqual(PointOrder.reversed.apply(to: one), one)
    }

    /// `.swept` is the one mode that is not a function of the point positions, so
    /// applied on its own it has nothing to reorder and must return the points
    /// untouched. `CurveLine.orderedPoints` is what resolves an actual sweep.
    func testSweptOrderOnItsOwnLeavesThePointsAlone() {
        XCTAssertEqual(PointOrder.swept.apply(to: scattered), scattered)
    }

    /// Both the sidebar's 取点顺序 pop-up and the Operations menu build themselves
    /// by walking `allCases`, which is how this mode reaches the UI at all — so
    /// the list is worth asserting rather than assuming.
    func testSweptIsOfferedToTheUser() {
        XCTAssertEqual(PointOrder.swept.displayName, "重排顺序")
        XCTAssertTrue(PointOrder.allCases.contains(.swept))
        XCTAssertEqual(PointOrder.allCases.map(\.rawValue).count,
                       Set(PointOrder.allCases.map(\.rawValue)).count,
                       "原始值必须唯一,否则菜单项会指向同一个模式")
    }

    // MARK: - Diagnosis

    func testRightToLeftIsNotAFoldBack() {
        // Taken right to left: monotonic, and a curve is perfectly valid that way
        // once the order setting is understood.
        let backwards = [
            PixelPoint(x: 300, y: 0),
            PixelPoint(x: 200, y: 1),
            PixelPoint(x: 100, y: 2),
        ]
        let diagnosis = OrderDiagnosis(points: backwards)
        XCTAssertTrue(diagnosis.isMonotonicInX)
        XCTAssertEqual(diagnosis.reversals, 0)
    }

    func testFoldBackIsDetected() {
        // 100 → 300 → 150 → 250 turns twice.
        let folded = [
            PixelPoint(x: 100, y: 0),
            PixelPoint(x: 300, y: 1),
            PixelPoint(x: 150, y: 2),
            PixelPoint(x: 250, y: 3),
        ]
        let diagnosis = OrderDiagnosis(points: folded)
        XCTAssertFalse(diagnosis.isMonotonicInX)
        XCTAssertEqual(diagnosis.reversals, 2)
    }

    func testSortedOrderNeverReportsAFoldBack() {
        let diagnosis = OrderDiagnosis(points: PointOrder.ascendingX.apply(to: scattered))
        XCTAssertTrue(diagnosis.isMonotonicInX)
        XCTAssertEqual(diagnosis.reversals, 0)
    }

    func testSpanCoversTheExtractedPoints() {
        XCTAssertEqual(OrderDiagnosis(points: scattered).spanX, 100.0...300.0)
        XCTAssertNil(OrderDiagnosis(points: []).spanX)
    }

    /// A repeated x is a tie, not a reversal — a curve that pauses on one column
    /// must not be reported as doubling back.
    func testRepeatedXIsNotAReversal() {
        let runOfTwos = [
            PixelPoint(x: 100, y: 0),
            PixelPoint(x: 200, y: 1),
            PixelPoint(x: 200, y: 2),
            PixelPoint(x: 300, y: 3),
        ]
        let diagnosis = OrderDiagnosis(points: runOfTwos)
        XCTAssertTrue(diagnosis.isMonotonicInX)
        XCTAssertEqual(diagnosis.reversals, 0)
    }
}
