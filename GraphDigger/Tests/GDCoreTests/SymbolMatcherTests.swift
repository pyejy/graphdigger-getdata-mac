import XCTest
@testable import GDCore

/// The scatter-plot digitizer: one point per glyph, at the glyph's centre.
///
/// Two ways to be wrong are what most of this file is about, because both produce
/// a plausible-looking result on a chart of circles and are wrong the moment the
/// glyphs are anything else:
///
///   · **the bounding box's centre instead of the ink's** — indistinguishable on
///     a circle, off by a sixth of the height on a triangle;
///   · **no filtering at all** — which returns the legend key and the fitted line
///     as data, silently, because they are the same colour as the points.
///
/// The tolerances are not round numbers chosen for comfort: the worst deviation
/// measured across the renderer's own fixtures is 0.0301 px (on triangles; circles
/// and squares come out exact). Asserting 0.05 leaves a real margin while still
/// failing on a shift of a fifth of a pixel.
final class SymbolMatcherTests: XCTestCase {

    private static let deviationTolerance = 0.05

    // MARK: - Fixtures

    /// A mask with ink wherever the closure says, built by hand so the shape
    /// under test is the shape that was asked for.
    private func mask(width: Int, height: Int,
                      _ isInk: (Int, Int) -> Bool) -> ForegroundMask {
        var bits = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width where isInk(x, y) { bits[y * width + x] = true }
        }
        return ForegroundMask(width: width, height: height, bits: bits)
    }

    /// A filled disc, the way the renderer draws one.
    private func disc(cx: Double, cy: Double, diameter: Double) -> (Int, Int) -> Bool {
        let r = diameter / 2
        return { x, y in
            let dx = Double(x) - cx, dy = Double(y) - cy
            return dx * dx + dy * dy <= r * r
        }
    }

    /// The worst distance from any recorded centre to the nearest returned point,
    /// plus how many were missed. The pairing is nearest-neighbour because a
    /// matcher is not obliged to return the points in the order the fixture drew
    /// them — the count and the distances together are what make it 1:1.
    private func worstDeviation(_ result: [PixelPoint], from truth: [PixelPoint]) -> Double {
        var worst = 0.0
        for expected in truth {
            let nearest = result
                .map { hypot($0.x - expected.x, $0.y - expected.y) }
                .min() ?? .infinity
            worst = max(worst, nearest)
        }
        return worst
    }

    private func match(_ chart: SyntheticChart.ScatterChart,
                       diameter: Double? = nil) -> SymbolMatcher.Result {
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.markerColor,
                                        tolerance: 60,
                                        backgroundColor: chart.backgroundColor)
        return SymbolMatcher.match(
            mask: mask,
            options: SymbolMatcher.Options(expectedDiameter: diameter ?? Double(chart.markerDiameter)))
    }

    // MARK: - Finding the glyphs

    func testEveryCircleIsFoundAtItsCentre() {
        let chart = SyntheticChart.renderScatter(count: 24, markerDiameter: 11)
        let result = match(chart)

        XCTAssertEqual(result.points.count, chart.markerCentres.count,
                       "24 个圆应当找到 24 个点,实际 \(result.points.count)")
        XCTAssertEqual(result.rejectedTooSmall, 0)
        XCTAssertEqual(result.rejectedTooLarge, 0)
        XCTAssertEqual(result.rejectedOddShape, 0)
        XCTAssertLessThanOrEqual(worstDeviation(result.points, from: chart.markerCentres),
                                 Self.deviationTolerance)
    }

    /// The same chart with the other two glyph shapes, cycled.
    ///
    /// A matcher tuned to a disc passes the circle test and fails here twice over:
    /// a triangle's box is filled 0.5 rather than 0.785, which a fill-ratio floor
    /// set to a disc's shape would reject, and its mass sits above its box centre.
    func testSquaresAndTrianglesAreFoundToo() {
        let chart = SyntheticChart.renderScatter(count: 24, markerDiameter: 11,
                                                shapes: [.circle, .square, .triangle])
        let result = match(chart)

        XCTAssertTrue(chart.markerShapes.contains(.triangle), "固定装置里得有三角形,否则这条断言是空的")
        XCTAssertEqual(result.points.count, chart.markerCentres.count,
                       "三种形状混排应当全部找到,实际 \(result.points.count),"
                       + "过小 \(result.rejectedTooSmall) 过大 \(result.rejectedTooLarge)"
                       + " 形状不符 \(result.rejectedOddShape)")
        XCTAssertLessThanOrEqual(worstDeviation(result.points, from: chart.markerCentres),
                                 Self.deviationTolerance)
    }

    /// The centre is the ink's, not the box's — asserted so that the wrong
    /// implementation cannot pass.
    ///
    /// The two candidates are computed here and required to be far enough apart
    /// that the tolerance above cannot admit both. Without that second assertion
    /// this test would pass against the box centre on any glyph whose ink happens
    /// to be balanced, which is the whole family of glyphs such a test is usually
    /// written with.
    func testTheCentreIsTheCentreOfMassNotTheBoundingBox() {
        let diameter = 11.0
        let centre = (x: 100.0, y: 100.0)
        let half = diameter / 2
        // Apex up, base along the bottom of the box — the same triangle the
        // renderer draws.
        let apex = (x: centre.x, y: centre.y - half)
        let left = (x: centre.x - half, y: centre.y + half)
        let right = (x: centre.x + half, y: centre.y + half)
        func cross(_ p: (x: Double, y: Double), _ q: (x: Double, y: Double),
                   _ r: (x: Double, y: Double)) -> Double {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let m = mask(width: 140, height: 140) { x, y in
            let p = (x: Double(x), y: Double(y))
            let d1 = cross(apex, left, p), d2 = cross(left, right, p), d3 = cross(right, apex, p)
            return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
        }
        let result = SymbolMatcher.match(mask: m, options: SymbolMatcher.Options(expectedDiameter: diameter))
        XCTAssertEqual(result.points.count, 1, "手搭的三角形应当只找到一个符号")

        let boxCentre = PixelPoint(x: centre.x, y: centre.y)
        let inkCentre = PixelPoint(x: centre.x, y: centre.y + diameter / 6)
        guard let found = result.points.first else { return XCTFail("没找到") }

        XCTAssertLessThanOrEqual(hypot(found.x - inkCentre.x, found.y - inkCentre.y), 0.5,
                                 "应当落在墨迹质心,实际 (\(found.x),\(found.y))")
        XCTAssertGreaterThan(hypot(inkCentre.x - boxCentre.x, inkCentre.y - boxCentre.y), 0.5,
                             "固定装置里两个候选点必须分得开,否则这条断言验不出东西")
    }

    // MARK: - What is deliberately not a data point

    /// Once: two specks. One at 900×640 with a scatter drawn on it, twice: a
    /// legend key and an axis rule, both in the markers' own colour.
    func testALegendKeyAndTintedAxesAreNotDataPoints() {
        let chart = SyntheticChart.renderScatter(count: 20, markerDiameter: 11,
                                                legendSwatch: true, tintedAxes: true)
        let result = match(chart)

        XCTAssertEqual(result.points.count, chart.markerCentres.count,
                       "图例色块与坐标轴不该被当成数据点,实际找到 \(result.points.count) 个")
        XCTAssertGreaterThanOrEqual(result.rejectedTooLarge, 2,
                                    "图例与坐标轴应当被记为「过大」而不是消失")
        XCTAssertLessThanOrEqual(worstDeviation(result.points, from: chart.markerCentres),
                                 Self.deviationTolerance)
    }

    /// Specks and lines are counted, not silently dropped.
    ///
    /// Silently is the dangerous verb here. A matcher that discards what it does
    /// not understand returns a short list on a clean chart and a *wrong* list on
    /// a noisy one, with nothing on screen to say which happened — telling the
    /// two apart is exactly what the counts are for.
    func testSpecksAndLinesAreReportedRatherThanSilentlyDropped() {
        let glyph = disc(cx: 40, cy: 40, diameter: 11)
        let m = mask(width: 120, height: 120) { x, y in
            if glyph(x, y) { return true }
            // A one-pixel-wide diagonal: an admissible area at this diameter, the
            // wrong shape.
            if y == 80 + (x - 40) / 3 { return true }
            // Specks: single pixels scattered about.
            if (x * 7 + y * 13) % 31 == 0 && x > 60 && y < 30 { return true }
            return false
        }
        let result = SymbolMatcher.match(mask: m, options: SymbolMatcher.Options(expectedDiameter: 11))

        XCTAssertEqual(result.points.count, 1, "只该留下那个圆")
        XCTAssertGreaterThan(result.rejectedTooSmall, 0, "散点应当被记为「过小」")
        XCTAssertGreaterThan(result.rejectedOddShape, 0, "细长斜线应当被记为「形状不符」")
        XCTAssertEqual(result.points.first.map { hypot($0.x - 40, $0.y - 40) } ?? .infinity,
                       0, accuracy: 0.5)
    }

    // MARK: - Order, and what the knob is for

    func testTheResultIsInReadingOrder() {
        let chart = SyntheticChart.renderScatter(count: 30, markerDiameter: 9)
        let result = match(chart)
        XCTAssertEqual(result.points.count, 30)
        for (a, b) in zip(result.points, result.points.dropFirst()) {
            XCTAssertLessThanOrEqual(a.x, b.x, "结果必须按 x 不减排列(阅读序)")
        }
    }

    /// A diameter estimate that is far out finds nothing — and says *which* way it
    /// was wrong, which is the only thing that lets the user fix it.
    func testAWronglyGuessedDiameterFindsNothingAndSaysWhy() {
        let chart = SyntheticChart.renderScatter(count: 20, markerDiameter: 11)

        let tooSmall = match(chart, diameter: 3)
        XCTAssertEqual(tooSmall.points.count, 0, "把符号估得远小于实际,不该有结果")
        XCTAssertEqual(tooSmall.rejectedTooLarge, 20, "真实符号应当全被记为「过大」")

        let tooLarge = match(chart, diameter: 22)
        XCTAssertEqual(tooLarge.points.count, 0, "把符号估得远大于实际,不该有结果")
        XCTAssertEqual(tooLarge.rejectedTooSmall, 20, "真实符号应当全被记为「过小」")
    }

    /// Markers that touch merge into one component, and the honest outcome is a
    /// shorter list plus a count of what was thrown away — not a guess.
    ///
    /// This is a real limitation and it is documented rather than papered over:
    /// splitting a blob back into the glyphs that made it needs a shape model the
    /// tool does not have, and inventing two points where the ink says one is
    /// worse than reporting that the size estimate no longer matches the chart.
    func testMarkersThatTouchAreReportedRatherThanHalfReturned() {
        // 120 markers across the same axis span: a 5.9-pixel pitch against an
        // 11-pixel glyph, so neighbours overlap.
        let chart = SyntheticChart.renderScatter(count: 120, markerDiameter: 11)
        let result = match(chart)

        XCTAssertLessThan(result.points.count, chart.markerCentres.count,
                          "重叠的符号会被并成一个连通域,结果必然少于真值")
        XCTAssertGreaterThan(result.rejectedTooLarge, 0,
                             "被并掉的连通域必须被记下来,否则用户看不出是尺寸估错了")
        // And what *was* returned is still real: every accepted point sits on a
        // true centre rather than on the middle of a merged pair.
        for point in result.points {
            let nearest = chart.markerCentres
                .map { hypot($0.x - point.x, $0.y - point.y) }
                .min() ?? .infinity
            XCTAssertLessThanOrEqual(nearest, 1.0,
                                     "接受的点 (\(point.x),\(point.y)) 不在任何真实符号上")
        }
    }

    // MARK: - Degenerate input

    func testAnEmptyMaskYieldsNothingAndSaysSo() {
        let empty = ForegroundMask(width: 40, height: 40,
                                   bits: [Bool](repeating: false, count: 1600))
        let result = SymbolMatcher.match(mask: empty,
                                         options: SymbolMatcher.Options(expectedDiameter: 11))
        XCTAssertEqual(result.points.count, 0)
        XCTAssertEqual(result.componentCount, 0)
        XCTAssertFalse(result.hasRejections, "什么都没有,就什么都不该被记账")
    }

    func testAZeroDiameterIsRefusedRatherThanDividingByZero() {
        let m = mask(width: 40, height: 40, disc(cx: 20, cy: 20, diameter: 9))
        let result = SymbolMatcher.match(mask: m, options: SymbolMatcher.Options(expectedDiameter: 0))
        XCTAssertEqual(result.points.count, 0, "直径为 0 的估计不该被当成「全部接受」")
    }
}
