import XCTest
import GDCore

final class DigitizerTests: XCTestCase {

    // MARK: - Helpers

    /// Full-scale-relative error of each extracted point against the generator's
    /// ground-truth polyline, measured on the value (Y) axis.
    private func yErrors(_ extracted: [PixelPoint], chart: SyntheticChart.Chart) -> [Double] {
        let map = chart.calibration
        let truth = chart.curvePixels
        let span: Double
        if chart.isLogY {
            span = log10(chart.yMaxValue) - log10(chart.yMinValue)
        } else {
            span = chart.yMaxValue - chart.yMinValue
        }
        return extracted.map { p in
            // Nearest ground-truth sample by column.
            var bestIndex = 0
            var bestDistance = Double.infinity
            for (i, t) in truth.enumerated() {
                let d = abs(t.x - p.x)
                if d < bestDistance { bestDistance = d; bestIndex = i }
            }
            let trueY = truth[bestIndex].y
            let extractedValue = (try? map.y.value(atPixel: p.y)) ?? .nan
            let trueValue = (try? map.y.value(atPixel: trueY)) ?? .nan
            if chart.isLogY {
                return abs(log10(extractedValue) - log10(trueValue)) / span
            }
            return abs(extractedValue - trueValue) / span
        }
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let rank = p / 100.0 * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return sorted[lower] }
        let frac = rank - Double(lower)
        return sorted[lower] * (1 - frac) + sorted[upper] * frac
    }

    /// The FRD's headline acceptance criterion: p95 full-scale error <= 0.5%.
    private static let accuracyTarget = 0.005

    // MARK: - Foreground mask

    func testMaskSelectsCurveOnBackground() {
        let chart = SyntheticChart.render()
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        let foregroundCount = mask.bits.filter { $0 }.count
        XCTAssertGreaterThan(foregroundCount, 1_000)
        XCTAssertLessThan(Double(foregroundCount), Double(mask.bits.count) * 0.2)
        // The seed pixel of the curve must be foreground.
        XCTAssertTrue(mask.isForeground(x: Int(chart.curvePixels[0].x.rounded()),
                                        y: Int(chart.curvePixels[0].y.rounded())))
    }

    // MARK: - Area digitising

    func testAreaDigitizeAccuracyLinear() {
        let chart = SyntheticChart.render()
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        let rect = PixelRect(x0: chart.axisX0 + 2, y0: chart.axisY1,
                             x1: chart.axisX1, y1: chart.axisY0 - 2)

        for dx in [4, 8, 16] {
            let points = AreaDigitizer.digitize(mask: mask, rect: rect, dx: dx)
            XCTAssertGreaterThan(points.count, 40, "dx=\(dx)")
            let errors = yErrors(points, chart: chart)
            let p95 = percentile(errors, 95)
            XCTAssertLessThanOrEqual(p95, Self.accuracyTarget,
                                     "dx=\(dx) p95=\(p95) max=\(errors.max() ?? 0)")
        }
    }

    func testAreaDigitizeAccuracyLogAxis() {
        let chart = SyntheticChart.render(function: { 0.2 * pow(10, $0 / 3.5) },
                                          isLogY: true)
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        let rect = PixelRect(x0: chart.axisX0 + 2, y0: chart.axisY1,
                             x1: chart.axisX1, y1: chart.axisY0 - 2)
        let points = AreaDigitizer.digitize(mask: mask, rect: rect, dx: 6)
        XCTAssertGreaterThan(points.count, 100)
        let p95 = percentile(yErrors(points, chart: chart), 95)
        XCTAssertLessThanOrEqual(p95, 0.01, "log-axis p95=\(p95)")
    }

    func testAreaDigitizeAccuracyAcrossCurveFamilies() {
        let families: [(String, (Double) -> Double)] = [
            ("linear",   { 0.3 * $0 + 0.2 }),
            ("parabola", { 0.04 * ($0 - 5) * ($0 - 5) + 0.3 }),
            ("sine",     { 2.5 + 2 * sin($0 * 1.2) }),
            ("exp",      { 0.2 * exp($0 / 3.0) }),
        ]
        let rect: (SyntheticChart.Chart) -> PixelRect = {
            PixelRect(x0: $0.axisX0 + 2, y0: $0.axisY1, x1: $0.axisX1, y1: $0.axisY0 - 2)
        }
        for (name, fn) in families {
            let chart = SyntheticChart.render(function: fn)
            let mask = ForegroundMask.build(from: chart.buffer,
                                            lineColor: chart.lineColor,
                                            tolerance: 60)
            let points = AreaDigitizer.digitize(mask: mask, rect: rect(chart), dx: 8)
            let p95 = percentile(yErrors(points, chart: chart), 95)
            XCTAssertLessThanOrEqual(p95, Self.accuracyTarget, "\(name) p95=\(p95)")
        }
    }

    // MARK: - Line tracing

    func testTraceFollowsSolidCurveEndToEnd() throws {
        let chart = SyntheticChart.render()
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        let result = try TraceDigitizer.trace(mask: mask, from: chart.curvePixels[0])
        XCTAssertNil(result.branchPoint)
        XCTAssertGreaterThan(result.points.count, 700)
        let last = result.points.last!
        let truthEnd = chart.curvePixels.last!
        XCTAssertEqual(last.x, truthEnd.x, accuracy: 8)
        XCTAssertEqual(last.y, truthEnd.y, accuracy: 8)
    }

    func testTraceBridgesDashedCurve() throws {
        let chart = SyntheticChart.render()
        var mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        // Punch periodic 3px gaps to simulate a dashed stroke.
        var x = chart.axisX0 + 14
        while x < chart.axisX1 - 3 {
            for gx in x..<(x + 3) {
                for y in 0..<mask.height { mask.bits[y * mask.width + gx] = false }
            }
            x += 12
        }
        // A 3px-wide gap on a shallow-sloped stretch needs a 5px reach; the
        // default of 4 stops short, which matches the reference implementation.
        var options = TraceDigitizer.Options()
        options.bridgePixels = 5
        let result = try TraceDigitizer.trace(mask: mask, from: chart.curvePixels[0],
                                              options: options)
        XCTAssertGreaterThan(result.points.count, 200)
        XCTAssertEqual(result.points.last!.x, chart.curvePixels.last!.x, accuracy: 15)
    }

    func testTraceStopsAtPerpendicularCrossing() throws {
        let chart = SyntheticChart.render()
        var mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        let junction = chart.curvePixels[chart.curvePixels.count / 2]
        let jx = Int(junction.x.rounded()), jy = Int(junction.y.rounded())
        for y in max(0, jy - 60)...min(mask.height - 1, jy + 60) {
            mask.bits[y * mask.width + jx] = true
        }
        let result = try TraceDigitizer.trace(mask: mask, from: chart.curvePixels[0])
        let branch = try XCTUnwrap(result.branchPoint, "expected a junction stop")
        XCTAssertEqual(branch.x, Double(jx), accuracy: 15)
    }

    /// Regression: an earlier iteration reported a phantom junction partway up a
    /// single steep log-scale curve. It must trace cleanly.
    func testTraceNoFalseBranchOnSteepCleanCurve() throws {
        let chart = SyntheticChart.render(function: { 0.2 * pow(10, $0 / 3.5) },
                                          isLogY: true)
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        let result = try TraceDigitizer.trace(mask: mask, from: chart.curvePixels[0])
        XCTAssertNil(result.branchPoint)
        XCTAssertEqual(result.points.last!.x, chart.curvePixels.last!.x, accuracy: 8)
    }

    func testTraceRejectsSeedOffTheCurve() {
        let chart = SyntheticChart.render()
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        XCTAssertThrowsError(try TraceDigitizer.trace(mask: mask,
                                                      from: PixelPoint(x: 5, y: 5)))
    }

    // MARK: - Grid direction and phase (FR-5.4 / FR-5.5)

    /// A mask whose ink is wherever `isInk` says, built by hand so the shape under
    /// test is the shape that was asked for — no rendering, no thresholding, no
    /// question of whether the generator drew what the test meant.
    private func mask(width: Int, height: Int, _ isInk: (Int, Int) -> Bool) -> ForegroundMask {
        var bits = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width where isInk(x, y) { bits[y * width + x] = true }
        }
        return ForegroundMask(width: width, height: height, bits: bits)
    }

    /// Total length of the polyline through `points`, in pixels.
    ///
    /// The measure the grid direction actually moves: both grids find points on
    /// the same curve, and what differs is whether consecutive samples are
    /// *neighbours* on it. A sequence that zigzags between two branches traces a
    /// far longer path than one that walks along.
    private func pathLength(_ points: [PixelPoint]) -> Double {
        zip(points, points.dropFirst())
            .reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// The case the Y grid exists for: `x = f(y)`.
    ///
    /// A wavy line standing on end. Every row meets it once; most columns meet it
    /// several times. The X grid is not *imprecise* here — it finds points, they
    /// are on the curve, and the sequence is still wrong, because sampling by
    /// column answers a question the curve is not a function of. Swapping the axes
    /// turns it into the ordinary single-valued case.
    func testYGridFollowsACurveThatTurnsOnItsSide() {
        let width = 80, height = 120
        let curve: (Double) -> Double = { 40 + 18 * sin($0 / 12) }
        let m = mask(width: width, height: height) { x, y in
            abs(Double(x) - curve(Double(y))) <= 1.5
        }
        let rect = PixelRect(x0: 0, y0: 0, x1: width - 1, y1: height - 1)

        let byRow = AreaDigitizer.digitize(mask: m, rect: rect, dx: 6, axis: .y)
        let byColumn = AreaDigitizer.digitize(mask: m, rect: rect, dx: 6, axis: .x)

        // One sample per scanned row, and in order — the property the user is
        // buying.
        XCTAssertEqual(byRow.count, 20, "行扫描应当每行一个点")
        XCTAssertTrue(zip(byRow, byRow.dropFirst()).allSatisfy { $1.y > $0.y },
                      "Y 网格的点序必须按行递增")
        for point in byRow {
            XCTAssertEqual(point.x, curve(point.y), accuracy: 2.0, "y=\(point.y)")
        }

        // The column sweep visits the crossings column by column, so consecutive
        // samples jump between branches that are far apart on the curve.
        XCTAssertFalse(zip(byColumn, byColumn.dropFirst()).allSatisfy { $1.y >= $0.y },
                       "X 网格在同一条竖着的线上是来回跳的 —— 这正是要能换轴的原因")
        XCTAssertLessThan(pathLength(byRow), pathLength(byColumn) * 0.5,
                          "Y 网格的折线应当明显短于 X 网格的来回跳")
    }

    /// The strongest statement available about the new axis.
    ///
    /// Scanning a picture by column must give exactly the same points as scanning
    /// its transpose by row, with the coordinates swapped. This is what makes the
    /// Y grid trustworthy rather than merely plausible: it says the second axis is
    /// the same algorithm seen from the other side, not a second implementation
    /// that happens to agree on one picture.
    func testTheTwoGridAxesAreExactTransposes() {
        let width = 70, height = 50
        let blobs = mask(width: width, height: height) { x, y in
            (x * 7 + y * 13) % 11 < 3
        }
        let transposed = mask(width: height, height: width) { x, y in
            blobs.isForeground(x: y, y: x)
        }
        let rect = PixelRect(x0: 3, y0: 2, x1: width - 4, y1: height - 3)
        let swapped = PixelRect(x0: 2, y0: 3, x1: height - 3, y1: width - 4)

        let byColumn = AreaDigitizer.digitize(mask: blobs, rect: rect, dx: 5, axis: .x, phase: 2)
        let byRow = AreaDigitizer.digitize(mask: transposed, rect: swapped, dx: 5, axis: .y, phase: 2)

        XCTAssertFalse(byColumn.isEmpty, "固定装置本身要有点,否则这条断言是空的")
        XCTAssertEqual(byColumn.count, byRow.count)
        for (p, q) in zip(byColumn, byRow) {
            XCTAssertEqual(p.x, q.y, accuracy: 1e-12)
            XCTAssertEqual(p.y, q.x, accuracy: 1e-12)
        }
    }

    /// The phase moves the lattice, and only by its residue — FR-5.5.
    func testThePhaseMovesTheLattice() {
        // Every column has ink, so a scan line that exists produces a point and
        // the columns of the result are exactly the lines that were scanned.
        let m = mask(width: 64, height: 8) { _, _ in true }
        let rect = PixelRect(x0: 5, y0: 0, x1: 60, y1: 7)
        let dx = 8

        let shifted = AreaDigitizer.digitize(mask: m, rect: rect, dx: dx, phase: 3)
        XCTAssertFalse(shifted.isEmpty)
        XCTAssertTrue(shifted.allSatisfy { Int($0.x) % dx == 3 },
                      "线要落在 3 + 8k 上,实测 \(shifted.map { Int($0.x) })")

        // A whole spacing is the same grid. The value is persisted, so two
        // spellings of one grid comparing unequal would surface as a spurious
        // 「未保存」 on a document nobody touched.
        let plusOne = AreaDigitizer.digitize(mask: m, rect: rect, dx: dx, phase: 3 + dx)
        let minusOne = AreaDigitizer.digitize(mask: m, rect: rect, dx: dx, phase: 3 - dx)
        XCTAssertEqual(shifted.map(\.x), plusOne.map(\.x))
        XCTAssertEqual(shifted.map(\.x), minusOne.map(\.x))

        // And every phase actually moves it: 0 and 3 must not agree.
        let unshifted = AreaDigitizer.digitize(mask: m, rect: rect, dx: dx, phase: 0)
        XCTAssertNotEqual(shifted.map(\.x), unshifted.map(\.x))
    }

    /// The lattice is anchored to the picture, not to the selection.
    ///
    /// This is what makes 「对齐一次」 worth doing. If the grid hung off the
    /// rectangle's corner, redrawing the selection — which the user does on every
    /// pass — would slide every line, and the alignment would have to be redone
    /// each time. Anchored to the image, a second selection only clips the same
    /// grid shorter.
    func testTheLatticeIsAnchoredToTheImageNotToTheSelection() {
        let m = mask(width: 80, height: 8) { _, _ in true }
        let wide = AreaDigitizer.digitize(mask: m,
                                          rect: PixelRect(x0: 3, y0: 0, x1: 70, y1: 7),
                                          dx: 8, phase: 1)
        // The second selection starts 10 pixels in, **not** 8: a difference of a
        // whole spacing would put a rectangle-relative grid on the same lines by
        // coincidence, and the fixture would pass against the bug it exists to
        // catch. (It did, until a mutation test pointed it out.)
        let narrow = AreaDigitizer.digitize(mask: m,
                                            rect: PixelRect(x0: 13, y0: 0, x1: 70, y1: 7),
                                            dx: 8, phase: 1)
        let wideColumns = Set(wide.map { Int($0.x) })
        let narrowColumns = Set(narrow.map { Int($0.x) })

        XCTAssertFalse(narrowColumns.isEmpty)
        XCTAssertTrue(narrowColumns.isSubset(of: wideColumns),
                      "第二个选框只是把网格裁短,不该把线挪走:\(narrowColumns.sorted()) ⊄ \(wideColumns.sorted())")
    }
}
