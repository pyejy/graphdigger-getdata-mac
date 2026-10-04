import XCTest
@testable import GDCore

/// 取点密度: thinning a traced path to one point every `minSpacing` pixels.
///
/// The walk visits a pixel at a time, so an unthinned trace hands the user as
/// many points as the curve is long. What this pass may *not* do is move them:
/// the points are the extracted data, and a thinning that interpolated would put
/// them between pixels — off the curve — while looking perfectly reasonable in a
/// plot. Every check here is about what survives, not only about how many.
final class TraceDecimationTests: XCTestCase {

    private func straight(_ count: Int, step: Double = 1) -> [PixelPoint] {
        (0..<count).map { PixelPoint(x: Double($0) * step, y: 100) }
    }

    // MARK: - The rule

    func testSpacingOneLeavesTheWalkAlone() {
        let walk = straight(50)
        XCTAssertEqual(TraceDigitizer.decimate(walk, minSpacing: 1), walk)
        XCTAssertEqual(TraceDigitizer.decimate(walk, minSpacing: 0), walk)
        XCTAssertEqual(TraceDigitizer.decimate(walk, minSpacing: -3), walk)
    }

    func testKeepsTheFirstAndLastPoint() {
        for spacing in [2.0, 7.0, 13.0, 40.0] {
            let walk = straight(97)
            let thinned = TraceDigitizer.decimate(walk, minSpacing: spacing)
            XCTAssertEqual(thinned.first, walk.first, "间距 \(spacing) 丢了起点")
            XCTAssertEqual(thinned.last, walk.last, "间距 \(spacing) 丢了终点")
        }
    }

    /// The end is appended even when the last stride is a short one, and that is
    /// the only gap allowed below the spacing — so a check on the gaps has to
    /// except exactly one.
    func testEveryGapButTheLastMeetsTheSpacing() {
        for spacing in [2.0, 5.0, 9.0, 16.0] {
            let walk = straight(101)
            let thinned = TraceDigitizer.decimate(walk, minSpacing: spacing)
            let gaps = zip(thinned, thinned.dropFirst()).dropLast()
                .map { hypot($1.x - $0.x, $1.y - $0.y) }
            XCTAssertFalse(gaps.isEmpty, "间距 \(spacing) 什么都没抽掉")
            for gap in gaps {
                XCTAssertGreaterThanOrEqual(gap, spacing - 1e-9,
                                            "间距 \(spacing) 出现了 \(gap) 的间隔")
            }
            // And the short tail is genuinely short, not a second rule.
            let tail = hypot(thinned.last!.x - thinned[thinned.count - 2].x,
                             thinned.last!.y - thinned[thinned.count - 2].y)
            XCTAssertLessThan(tail, spacing + 1e-9)
        }
    }

    /// A spacing wider than the whole path still yields two points: the two ends.
    /// Returning the path unchanged would be the quiet failure here — the knob
    /// would look inert over its last stretch.
    func testSpacingWiderThanThePathKeepsBothEnds() {
        let walk = straight(10)
        let thinned = TraceDigitizer.decimate(walk, minSpacing: 1_000)
        XCTAssertEqual(thinned, [walk.first!, walk.last!])
    }

    // MARK: - What must not happen

    func testEveryKeptPointWasWalked() {
        // A path with the shape of a traced curve: mostly rightward, with runs.
        var walk: [PixelPoint] = []
        for x in 0..<400 {
            walk.append(PixelPoint(x: Double(x), y: 200 + sin(Double(x) / 30) * 60))
        }
        let walked = Set(walk)
        for spacing in [3.0, 11.0, 37.0] {
            let thinned = TraceDigitizer.decimate(walk, minSpacing: spacing)
            for point in thinned {
                XCTAssertTrue(walked.contains(point),
                              "间距 \(spacing) 造出了没走过的点 \(point)")
            }
        }
    }

    func testKeepsTheOrder() {
        let walk = straight(120)
        let thinned = TraceDigitizer.decimate(walk, minSpacing: 8)
        XCTAssertEqual(thinned, thinned.sorted { $0.x < $1.x }, "抽稀打乱了顺序")
    }

    /// Distance is measured along the path, so a steep stretch keeps as many
    /// points per column of x as a flat one keeps per row of y. Thinning by x
    /// alone would leave a near-vertical segment with a single point and a
    /// horizontal one thick with them — the curve's shape is what is being
    /// sampled, so it has to be sampled evenly along its own length.
    func testSteepAndFlatStretchesThinTheSameWay() {
        let flat = straight(200)
        let steep: [PixelPoint] = (0..<200).map { PixelPoint(x: 50, y: Double($0)) }
        let flatThinned = TraceDigitizer.decimate(flat, minSpacing: 10)
        let steepThinned = TraceDigitizer.decimate(steep, minSpacing: 10)
        XCTAssertEqual(flatThinned.count, steepThinned.count)
    }

    // MARK: - Shapes that need guarding

    func testEmptyAndTinyPaths() {
        XCTAssertEqual(TraceDigitizer.decimate([], minSpacing: 10), [])
        let one = [PixelPoint(x: 3, y: 4)]
        XCTAssertEqual(TraceDigitizer.decimate(one, minSpacing: 10), one)
        let two = [PixelPoint(x: 0, y: 0), PixelPoint(x: 1, y: 0)]
        XCTAssertEqual(TraceDigitizer.decimate(two, minSpacing: 10), two)
    }

    /// A path that doubles back on itself — a trace rounding a peak — must not
    /// have the two sides of the turn merged: they are different pixels, and the
    /// thinning keeps whichever comes first in the walk.
    func testADoublingBackPathKeepsTheWalkedOrder() {
        var walk: [PixelPoint] = []
        for x in 0..<40 { walk.append(PixelPoint(x: Double(x), y: 100)) }
        for x in stride(from: 38, through: 0, by: -1) { walk.append(PixelPoint(x: Double(x), y: 120)) }
        let thinned = TraceDigitizer.decimate(walk, minSpacing: 5)
        XCTAssertEqual(thinned.first, walk.first)
        XCTAssertEqual(thinned.last, walk.last)
        for point in thinned { XCTAssertTrue(walk.contains(point)) }
    }

    // MARK: - The model's own default

    func testProjectStateStartsAtEveryPixel() {
        XCTAssertEqual(ProjectState().traceSpacing, 1,
                       "默认必须与原行为一致:每走一个像素取一个点")
        XCTAssertEqual(ProjectState().gridSpacing, 8)
    }

    func testProjectStateRoundTripsThroughCoding() throws {
        var state = ProjectState()
        state.traceSpacing = 7
        state.gridSpacing = 3
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(ProjectState.self, from: data)
        XCTAssertEqual(back.traceSpacing, 7)
        XCTAssertEqual(back.gridSpacing, 3)
    }
}
