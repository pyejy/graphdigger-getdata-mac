import XCTest
@testable import GDCore

/// 数据坐标绘图的两个轴：范围怎么取整、值落在纵深的哪里。
///
/// The failure this file exists to prevent is a plot that is *correct* and
/// unreadable: an axis running −0.2…1.2 for data that spans 0…1, with every label
/// a five-digit decimal. Both are arithmetic decisions, so both are pinned here
/// rather than looked at.
final class PlotAxisTests: XCTestCase {

    // MARK: - The range

    /// Rounding the ends outward **is** the margin — adding a margin first and
    /// then rounding doubles it.
    func testRangeEndsLandOnRoundNumbers() {
        let unit = PlotAxis.covering([0, 1])
        XCTAssertEqual(unit?.low, 0)
        XCTAssertEqual(unit?.high, 1)

        // The same data nudged off the round numbers must come back to the same
        // axis: this is the case that decides whether the labels are readable.
        let nudged = PlotAxis.covering([0.0371, 0.9982])
        XCTAssertEqual(nudged?.low, 0)
        XCTAssertEqual(nudged?.high, 1)

        let wider = PlotAxis.covering([3.1, 47.6])
        XCTAssertEqual(wider?.low, 0)
        XCTAssertEqual(wider?.high, 50)
    }

    /// Every axis has to contain its data, whatever it does about round numbers.
    func testEveryRangeContainsItsData() {
        for values in [[0.0, 1.0], [0.0371, 0.9982], [-3.3, 7.9], [3.1, 47.6],
                       [1e-4, 9e-4], [-50.0, -2.0]] {
            guard let range = PlotAxis.covering(values) else {
                XCTFail("\(values) 应当能取到范围"); continue
            }
            XCTAssertLessThanOrEqual(range.low, values.min()!, "\(values)")
            XCTAssertGreaterThanOrEqual(range.high, values.max()!, "\(values)")
        }
    }

    /// With nothing to span, the range still has to have width — a zero-width
    /// axis divides by zero somewhere downstream.
    func testEqualValuesGetAWindow() {
        let range = PlotAxis.covering([5, 5, 5])
        XCTAssertEqual(range?.low, 4.5)
        XCTAssertEqual(range?.high, 5.5)

        let zero = PlotAxis.covering([0, 0])
        XCTAssertEqual(zero?.low, -0.5)
        XCTAssertEqual(zero?.high, 0.5)
    }

    /// A log axis snaps to decades, because decades are the only round numbers
    /// on it.
    func testLogRangeSnapsToDecades() {
        let range = PlotAxis.covering([0.5, 20], isLogarithmic: true)
        XCTAssertEqual(range?.low, 0.1)
        XCTAssertEqual(range?.high, 100)

        // Non-positive values are not plotable on a log axis and must not
        // influence the range either.
        let withZero = PlotAxis.covering([0, 1, 10], isLogarithmic: true)
        XCTAssertEqual(withZero?.low, 1)
        XCTAssertEqual(withZero?.high, 10)
    }

    func testNothingFiniteGivesNoRange() {
        XCTAssertNil(PlotAxis.covering([]))
        XCTAssertNil(PlotAxis.covering([.nan, .infinity]))
        XCTAssertNil(PlotAxis.covering([0, -1], isLogarithmic: true))
    }

    // MARK: - The placement

    func testFractionSpansTheBand() {
        guard let axis = PlotAxis(low: 0, high: 10) else { return XCTFail("轴没建出来") }
        XCTAssertEqual(axis.fraction(0), 0)
        XCTAssertEqual(axis.fraction(5), 0.5)
        XCTAssertEqual(axis.fraction(10), 1)
        // Outside the band is reported as outside, not clamped: the view decides
        // whether to clip.
        XCTAssertEqual(axis.fraction(15), 1.5)
    }

    /// On a log axis the midpoint of 1…100 is 10, not 50.5 — and getting this
    /// wrong is invisible until someone reads a value off the plot.
    func testLogFractionPlacesByExponent() {
        guard let axis = PlotAxis(low: 1, high: 100, isLogarithmic: true) else {
            return XCTFail("轴没建出来")
        }
        XCTAssertEqual(axis.fraction(1), 0)
        XCTAssertEqual(axis.fraction(10) ?? .nan, 0.5, accuracy: 1e-12)
        XCTAssertEqual(axis.fraction(100), 1)
        XCTAssertEqual(axis.fraction(1000) ?? .nan, 1.5, accuracy: 1e-12)
    }

    func testALogAxisRefusesValuesItCannotPlace() {
        guard let axis = PlotAxis(low: 1, high: 100, isLogarithmic: true) else {
            return XCTFail("轴没建出来")
        }
        XCTAssertNil(axis.fraction(0))
        XCTAssertNil(axis.fraction(-5))
        XCTAssertNil(axis.fraction(.nan))
    }

    func testDegenerateAxesAreRefused() {
        XCTAssertNil(PlotAxis(low: 5, high: 5))
        XCTAssertNil(PlotAxis(low: .nan, high: 1))
        XCTAssertNil(PlotAxis(low: 0, high: 10, isLogarithmic: true))
        XCTAssertNotNil(PlotAxis(low: 0, high: 10))
    }

    // MARK: - The labels

    /// The ticks a reader gets: round, inside the range, ascending, and about as
    /// many as were asked for.
    func testLinearTicksAreRoundAndInsideTheRange() {
        guard let axis = PlotAxis(low: 0, high: 1, targetCount: 6) else {
            return XCTFail("轴没建出来")
        }
        // Compared with a tolerance, not bit-for-bit. 0.2 is not representable in
        // binary, so three of them are 0.6000000000000001 however the loop is
        // written; demanding the bit pattern would pin an implementation detail
        // rather than the property. What has to hold is that the value is 0.6 to
        // any tolerance a label cares about — and the label is *formatted* from
        // it (`DataPlotView.number`) rather than printed raw.
        let expected = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
        XCTAssertEqual(axis.ticks.count, expected.count, "刻度个数不对: \(axis.ticks)")
        for (tick, want) in zip(axis.ticks, expected) {
            XCTAssertEqual(tick, want, accuracy: 1e-12, "刻度 \(tick) 不是 \(want)")
        }
        for tick in axis.ticks {
            let fraction = axis.fraction(tick)
            XCTAssertNotNil(fraction)
            XCTAssertTrue((0...1).contains(fraction!), "刻度 \(tick) 落在带外")
        }
    }

    /// Density follows the span drawn, not the exponents the ends round to.
    func testLogTicksThinOutWhenThereIsALotToCover() {
        guard let wide = PlotAxis(low: 1, high: 1000, isLogarithmic: true) else {
            return XCTFail("轴没建出来")
        }
        XCTAssertEqual(wide.ticks, [1, 10, 100, 1000], "三个数量级只能用十进制挡位")

        guard let narrow = PlotAxis(low: 0.5, high: 20, isLogarithmic: true) else {
            return XCTFail("轴没建出来")
        }
        XCTAssertEqual(narrow.ticks, [0.5, 1, 2, 5, 10, 20], "1.6 个数量级可以挂 1-2-5")
    }

    /// A range with no round numbers inside it still has to say something.
    func testATinyRangeStillGetsTicks() {
        guard let axis = PlotAxis(low: 0.9968, high: 0.9991) else {
            return XCTFail("轴没建出来")
        }
        XCTAssertFalse(axis.ticks.isEmpty)
        for tick in axis.ticks {
            XCTAssertTrue((0.9968...0.9991).contains(tick), "刻度 \(tick) 跑到范围外了")
        }
    }

    /// Ticks are ascending in value whatever the axis direction, so the view can
    /// draw them without asking which way the axis runs.
    func testTicksAscendEvenOnAReversedAxis() {
        guard let reversed = PlotAxis(low: 10, high: 0) else { return XCTFail("轴没建出来") }
        XCTAssertEqual(reversed.ticks, reversed.ticks.sorted())
        XCTAssertEqual(reversed.fraction(0), 1)
        XCTAssertEqual(reversed.fraction(10), 0)
    }
}
