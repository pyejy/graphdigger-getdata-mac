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
}
