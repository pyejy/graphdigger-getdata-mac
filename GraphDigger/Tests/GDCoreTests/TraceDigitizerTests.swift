import XCTest
@testable import GDCore

/// 自动跟踪: which way the walk sets off, and what it does when the line turns.
///
/// Both halves come from one measured failure. On a synthetic chart 900×640,
/// seeded at the middle of the curve:
///
///     flat part,  (275,493) → 627 points
///     steep part, (470,310) →   4 points, reported as "reached the end"
///
/// The seed pixel was foreground, with 53 foreground neighbours in an 11×11
/// window, so the ink was there to be followed. Two separate causes:
///
/// 1. the first step was chosen by "the right-hand neighbour with the smallest
///    |dy|", so on a steep line it set off across the ink rather than along it —
///    and since the heading is initialised from that step, the walk could not
///    recover;
/// 2. a single step turning more than `forwardFanDegrees` was treated as the end
///    of the line, so a corner ended the trace too.
///
/// Asserted against the *outcome* — does the path follow the ink — rather than
/// against the direction chosen, because from a seed in the middle either
/// direction along the line is a correct answer.
///
/// Measured on a hand-built vertical wave, seed → points, before → after:
///
///     y=14 (line vertical here)   2 → 22
///     y=70 (line vertical here)   2 → 91
///     y=4 / 22 / 121 / 135      16/13/5/13 → 19/15/14/15
///     a 78° corner              120 (stopped) → 261 (both arms)
///
/// Not one seed came out worse.
final class TraceDigitizerTests: XCTestCase {

    // MARK: - Fixtures

    /// A mask whose ink is wherever `isInk` says, built by hand so the shape under
    /// test is the shape that was asked for — no rendering, no thresholding.
    private func mask(width: Int, height: Int, _ isInk: (Int, Int) -> Bool) -> ForegroundMask {
        var bits = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width where isInk(x, y) { bits[y * width + x] = true }
        }
        return ForegroundMask(width: width, height: height, bits: bits)
    }

    /// A polyline drawn with a given thickness.
    private func mask(width: Int, height: Int,
                      polyline: [PixelPoint], thickness: Double = 1.6) -> ForegroundMask {
        mask(width: width, height: height) { x, y in
            distance(from: PixelPoint(x: Double(x), y: Double(y)), to: polyline) <= thickness
        }
    }

    private func distance(from p: PixelPoint, to polyline: [PixelPoint]) -> Double {
        var best = Double.infinity
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            let vx = b.x - a.x, vy = b.y - a.y
            let lengthSquared = vx * vx + vy * vy
            let t = lengthSquared <= 0
                ? 0
                : max(0, min(1, ((p.x - a.x) * vx + (p.y - a.y) * vy) / lengthSquared))
            let dx = p.x - (a.x + t * vx), dy = p.y - (a.y + t * vy)
            best = min(best, (dx * dx + dy * dy).squareRoot())
        }
        return best
    }

    private func furthest(_ points: [PixelPoint], from polyline: [PixelPoint]) -> Double {
        points.map { distance(from: $0, to: polyline) }.max() ?? 0
    }

    private func pathLength(_ points: [PixelPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    // MARK: - The measured failure

    /// The reproduction, on the fixture it was measured on.
    ///
    /// Through the outcome, not the count alone: a walk that took many steps
    /// *away* from the curve would satisfy a count and be worse than the four
    /// points it replaced.
    func testASteepSeedFollowsTheCurveInsteadOfStoppingAtOnce() throws {
        let chart = SyntheticChart.render(lineWidth: 3)
        let m = ForegroundMask.build(from: chart.buffer,
                                    lineColor: chart.lineColor,
                                    tolerance: 60,
                                    backgroundColor: chart.backgroundColor)
        let seed = chart.curvePixels[chart.curvePixels.count / 2]
        XCTAssertTrue(m.isForeground(x: Int(seed.x), y: Int(seed.y)),
                      "固定装置本身要落在线上,否则这条断言是空的")

        let traced = try TraceDigitizer.trace(mask: m, from: seed)

        // The curve is 2001 samples long, so half of it is a few hundred pixels
        // of travel; anything near a handful of steps is the old failure.
        XCTAssertGreaterThan(traced.points.count, 100,
                             "陡段起点只走了 \(traced.points.count) 步 —— 正是修复前 4 步即停的样子")
        XCTAssertLessThanOrEqual(furthest(traced.points, from: chart.curvePixels), 3.0,
                                 "走过的点必须落在曲线上")
        XCTAssertLessThan(pathLength(traced.points), 1_500,
                          "折线长 \(Int(pathLength(traced.points))) 远超覆盖的曲线长度,是在乱走")
    }

    /// The seed sets off **along** the line, not across it.
    ///
    /// The tightest statement of the first cause: from the top of a near-vertical
    /// line, the old rule took the leftward neighbour (the only one with
    /// `|dy| = 0`) and set off across the 3-pixel band, which ended the walk at
    /// once. The step now goes down the line.
    func testTheSeedSetsOffAlongTheLineNotAcrossIt() throws {
        let width = 80, height = 170
        let truth = [PixelPoint(x: 40, y: 10), PixelPoint(x: 52, y: 160)]
        let m = mask(width: width, height: height, polyline: truth)

        let traced = try TraceDigitizer.trace(mask: m, from: PixelPoint(x: 40, y: 11))
        let first = traced.points[0], second = traced.points[1]

        XCTAssertGreaterThan(second.y, first.y,
                             "第一步应当沿线下走,实际走到了 (\(Int(second.x)),\(Int(second.y)))")
        XCTAssertLessThanOrEqual(abs(second.x - first.x), 1, "第一步横跨了线的宽度")
        XCTAssertGreaterThan(traced.points.map(\.y).max() ?? 0, 150,
                             "只走到 y=\(Int(traced.points.map(\.y).max() ?? 0)),线一直到 y=160")
        XCTAssertLessThanOrEqual(furthest(traced.points, from: truth), 2.5)
    }

    /// The vertical point of a wave — where the line is steepest — is a seed the
    /// old rule could not handle at all: 2 points, reported as "reached the end".
    func testSeedsAtTheVerticalPointsOfAWaveGetFurtherThanTheStart() throws {
        let width = 60, height = 140
        let curve: (Double) -> Double = { 30 + 20 * sin($0 / 9) }
        let truth = stride(from: 0.0, through: Double(height - 1), by: 0.5)
            .map { PixelPoint(x: curve($0), y: $0) }
        let m = mask(width: width, height: height, polyline: truth)

        // `f'(y) = (20/9)·cos(y/9)`, so the line is vertical at these y.
        for y in [14, 42, 70, 99, 127] {
            let x = Int(curve(Double(y)).rounded())
            guard m.isForeground(x: x, y: y) else { continue }
            let traced = try TraceDigitizer.trace(mask: m,
                                                  from: PixelPoint(x: Double(x), y: Double(y)))
            // Ten, not a hundred: a walk that leaves a vertical seed may still
            // stop at a tight bend (see the note in README's 已知限制). What it
            // may not do is stop where it started — that was the bug.
            XCTAssertGreaterThan(traced.points.count, 10,
                                 "y=\(y) 处线是竖直的,只走了 \(traced.points.count) 步(修复前是 2 步)")
            XCTAssertLessThanOrEqual(furthest(traced.points, from: truth), 2.5,
                                     "y=\(y) 的种子走离了曲线 \(furthest(traced.points, from: truth)) px")
        }
    }

    /// A corner is a turn, not the end of the line.
    ///
    /// The bend is 78°, past `forwardFanDegrees` (70°) but within a right angle,
    /// so it is what the widened fan is for. Sharp corners are ordinary on real
    /// charts: a plotted step, a V, the break in a titration curve.
    func testACornerIsFollowedAround() throws {
        let width = 220, height = 200
        let truth = [PixelPoint(x: 20, y: 160), PixelPoint(x: 140, y: 160), PixelPoint(x: 170, y: 20)]
        let m = mask(width: width, height: height, polyline: truth)

        let traced = try TraceDigitizer.trace(mask: m, from: PixelPoint(x: 22, y: 160))

        XCTAssertLessThanOrEqual(furthest(traced.points, from: truth), 2.5, "走过的点必须落在折线上")
        XCTAssertLessThan(traced.points.map(\.y).min() ?? 999, 40,
                          "拐角处停了,只走到 y=\(Int(traced.points.map(\.y).min() ?? 999))(第一条臂在 y=160)")
        XCTAssertEqual(traced.branchPoint, nil, "拐角不该被当成分支点")
    }

    /// The widened fan must not invent a continuation past the end of a line.
    func testTheEndOfALineIsStillTheEnd() throws {
        let width = 160, height = 40
        let truth = [PixelPoint(x: 20, y: 20), PixelPoint(x: 120, y: 20)]
        let m = mask(width: width, height: height, polyline: truth)

        let traced = try TraceDigitizer.trace(mask: m, from: PixelPoint(x: 21, y: 20))

        XCTAssertGreaterThan(traced.points.count, 80, "整条线应当走完")
        XCTAssertLessThanOrEqual(traced.points.map(\.x).max() ?? 0, 122,
                                 "越过了线的末端 —— 宽扇形不该从空处找出下一格")
        XCTAssertEqual(traced.branchPoint, nil)
    }

    /// A crossing is still crossed straight over.
    ///
    /// The concern a widened fan raises is that "nothing ahead" at a crossing
    /// would let the walk turn onto the other line. It cannot: there the ordinary
    /// fan already finds the straight-ahead continuation, so the second fan is
    /// never consulted. Asserted as "the walk stays on its own line", which holds
    /// whether it stops at the junction or passes through.
    func testACrossingIsNotTakenForACorner() throws {
        let width = 240, height = 200
        let m = mask(width: width, height: height) { x, y in
            let onHorizontal = abs(Double(y) - 100) <= 1.6 && x >= 20 && x <= 220
            let onVertical = abs(Double(x) - 120) <= 1.6 && y >= 20 && y <= 180
            return onHorizontal || onVertical
        }

        let traced = try TraceDigitizer.trace(mask: m, from: PixelPoint(x: 22, y: 100))

        let strayed = traced.points.filter { abs($0.y - 100) > 3 }
        XCTAssertTrue(strayed.isEmpty,
                      "走上了交叉的那条线:\(strayed.prefix(4).map { "(\(Int($0.x)),\(Int($0.y)))" })")
    }

    /// The ordinary case, unchanged: a flat line read from its left end still
    /// goes left to right, a step at a time, to the far end.
    ///
    /// The seed rule was rewritten, so this is the guard that it did not cost the
    /// behaviour it was written for.
    func testAFlatLineIsStillReadLeftToRight() throws {
        let width = 200, height = 40
        let truth = [PixelPoint(x: 20, y: 20), PixelPoint(x: 180, y: 20)]
        let m = mask(width: width, height: height, polyline: truth)

        let traced = try TraceDigitizer.trace(mask: m, from: PixelPoint(x: 21, y: 20))

        XCTAssertTrue(zip(traced.points, traced.points.dropFirst()).allSatisfy { $1.x >= $0.x },
                      "自左端点起应当一路向右")
        XCTAssertGreaterThan(traced.points.map(\.x).max() ?? 0, 175, "没走到右端点")
    }
}
