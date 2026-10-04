import XCTest
@testable import GDCore

/// 前景掩膜:加在距离、背景之后的第三道闸门 —— 色相。
///
/// 报告的场景是「绿曲线和橙曲线色差这么大,区域取点还是取到了橙曲线上」。
/// 这些测试存在的理由就是那个场景能被复现:每一条都先证明**关掉闸门时确实会
/// 混色**,再证明打开后不会。只断言后者的测试,一个把整条曲线都丢掉的实现也能
/// 通过——那正是这类修法最容易犯的错。
final class ForegroundMaskTests: XCTestCase {

    /// 报告里那张图的真实颜色,直接从截图上取的像素。
    private let green = RGB8(r: 103, g: 186, b: 103)
    private let orange = RGB8(r: 255, g: 164, b: 84)
    private let page = RGB8(r: 254, g: 254, b: 254)

    /// 闸门关掉时的取值。180° 意味着「任何色相都算」。
    private let gateOff = 180.0

    // MARK: - Helpers

    /// A one-row buffer, one pixel per colour.
    private func strip(_ colors: [RGB8]) -> BitmapBuffer {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(colors.count * 3)
        for c in colors { pixels.append(contentsOf: [c.r, c.g, c.b]) }
        return BitmapBuffer(width: colors.count, height: 1, pixels: pixels)
    }

    /// The colour of a stroke pixel drawn at coverage `t` over `background`:
    /// `t·ink + (1-t)·background`. This is what anti-aliasing does, and it is the
    /// only thing it does.
    private func blend(_ ink: RGB8, over background: RGB8, coverage t: Double) -> RGB8 {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((t * Double(a) + (1 - t) * Double(b)).rounded()) }
        return RGB8(r: mix(ink.r, background.r), g: mix(ink.g, background.g), b: mix(ink.b, background.b))
    }

    /// A colour's distance from the grey axis — how much hue it carries.
    private func chroma(_ c: RGB8) -> Double {
        let m = (Double(c.r) + Double(c.g) + Double(c.b)) / 3
        let v = [Double(c.r) - m, Double(c.g) - m, Double(c.b) - m]
        return (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
    }

    /// 5×5 box blur, standing in for the anti-aliasing of a real screenshot.
    ///
    /// The synthetic charts draw solid discs with hard edges, so not one pixel of
    /// their orange stroke is "orange blended with white" — and that rim is
    /// precisely where the reported leak lives. Without this step the scenario
    /// cannot be reproduced in a test at all.
    ///
    /// Radius 2 rather than 1 because the coverage steps a box blur produces are
    /// `1/(2r+1)²` apart: at radius 2 the ramp passes through 0.8, which is the
    /// last coverage the distance gate still admits for this pair of colours.
    private func softened(_ buffer: BitmapBuffer, radius: Int = 2) -> BitmapBuffer {
        var out = [UInt8](repeating: 0, count: buffer.width * buffer.height * 3)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                var sums = (0, 0, 0), n = 0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let sx = x + dx, sy = y + dy
                        guard sx >= 0, sx < buffer.width, sy >= 0, sy < buffer.height else { continue }
                        let c = buffer.color(atX: sx, y: sy)
                        sums = (sums.0 + Int(c.r), sums.1 + Int(c.g), sums.2 + Int(c.b))
                        n += 1
                    }
                }
                let i = (y * buffer.width + x) * 3
                out[i] = UInt8(sums.0 / n)
                out[i + 1] = UInt8(sums.1 / n)
                out[i + 2] = UInt8(sums.2 / n)
            }
        }
        return BitmapBuffer(width: buffer.width, height: buffer.height, pixels: out)
    }

    /// How many of `points` sit on the polyline `truth`, in rows.
    private func onCurve(_ points: [PixelPoint], _ truth: [PixelPoint], within rows: Double) -> Int {
        points.filter { p in
            guard let nearest = truth.min(by: { abs($0.x - p.x) < abs($1.x - p.x) }) else { return false }
            return abs(nearest.y - p.y) <= rows
        }.count
    }

    // MARK: - The gate keeps the curve it was aimed at

    /// Anti-aliasing fades a stroke towards the page without ever turning it
    /// into a different colour, so the gate must not take a single pixel of the
    /// curve away — at any opacity, down to the faintest rim.
    func testTheCurvesOwnInkSurvivesAtEveryOpacity() {
        let colors = (0...40).map { blend(green, over: page, coverage: Double($0) / 40) }
        let buffer = strip(colors)

        let loose = ForegroundMask.build(from: buffer, lineColor: green, tolerance: 60,
                                         backgroundColor: page, hueTolerance: gateOff)
        let gated = ForegroundMask.build(from: buffer, lineColor: green, tolerance: 60,
                                         backgroundColor: page)

        XCTAssertTrue(loose.bits.contains(true), "这条测试必须真的接受过一些像素,否则它在测空气")
        XCTAssertEqual(gated.bits, loose.bits, "闸门吃掉了曲线自己的墨")
    }

    // MARK: - The gate rejects the curve it was not aimed at

    /// The reported bug, reduced to its smallest form.
    ///
    /// Green and orange are 59.7 apart under the mask's weighted metric — inside
    /// the default tolerance of 60, even though they are 154.8 apart in plain RGB.
    /// The orange stroke is also nearer the green curve (59.7) than the white page
    /// (115.9), so the background gate waves it through: both older gates say yes.
    func testASecondHueInsideTheDistanceToleranceIsRejected() {
        XCTAssertLessThan(chroma(orange), 200, "前提:橙色是有色相的")
        XCTAssertEqual(ForegroundMask.build(from: strip([orange]), lineColor: green,
                                            tolerance: 60, backgroundColor: page,
                                            hueTolerance: gateOff).foregroundCount, 1,
                       "前提:橙色在默认容差内 —— 否则这条测试防的不是报告里的那个 bug")

        let gated = ForegroundMask.build(from: strip([orange]), lineColor: green,
                                         tolerance: 60, backgroundColor: page)
        XCTAssertEqual(gated.foregroundCount, 0, "橙色像素仍然被当成绿色曲线")
    }

    /// And the whole stroke, not just its core: every opacity of the wrong curve
    /// is wrong too, which is what makes the failure show up as a point sitting
    /// on the neighbouring curve rather than as a scattering of stray pixels.
    func testEveryOpacityOfTheSecondCurveIsRejected() {
        let colors = (0...40).map { blend(orange, over: page, coverage: Double($0) / 40) }
        let buffer = strip(colors)

        let loose = ForegroundMask.build(from: buffer, lineColor: green, tolerance: 60,
                                         backgroundColor: page, hueTolerance: gateOff)
        let gated = ForegroundMask.build(from: buffer, lineColor: green, tolerance: 60,
                                         backgroundColor: page)

        XCTAssertGreaterThan(loose.foregroundCount, 5,
                             "旧规则必须确实吃进一大片橙曲线,否则这条测试证明不了什么")
        XCTAssertEqual(gated.foregroundCount, 0, "闸门之后仍有 \(gated.foregroundCount) 个橙色像素")
    }

    // MARK: - And it stands down where it has nothing to say

    /// A pale curve — the case the background gate exists for — carries almost no
    /// chroma, so "which way does it point" has no reliable answer and the gate
    /// must not be allowed to guess. Its verdict has to be exactly what the older
    /// two gates reached on their own.
    func testTheGateStandsDownForColoursWithNoHueOfTheirOwn() {
        let pale = RGB8(r: 200, g: 205, b: 215)
        XCTAssertLessThan(chroma(pale), ForegroundMask.chromaFloor,
                          "前提:浅色曲线的色度必须低于闸门的门槛,否则这条测试没测到那条分支")

        let colors = (0...20).map { blend(pale, over: page, coverage: Double($0) / 20) }
        let buffer = strip(colors)
        let loose = ForegroundMask.build(from: buffer, lineColor: pale, tolerance: 60,
                                         backgroundColor: page, hueTolerance: gateOff)
        let gated = ForegroundMask.build(from: buffer, lineColor: pale, tolerance: 60,
                                         backgroundColor: page)
        XCTAssertEqual(gated.bits, loose.bits)
        XCTAssertTrue(loose.bits.contains(true))
    }

    func testTheGateStandsDownForAGreyLine() {
        let grey = RGB8(r: 128, g: 128, b: 128)
        let colors = (0...20).map { blend(grey, over: page, coverage: Double($0) / 20) }
        let buffer = strip(colors)
        let loose = ForegroundMask.build(from: buffer, lineColor: grey, tolerance: 60,
                                         backgroundColor: page, hueTolerance: gateOff)
        let gated = ForegroundMask.build(from: buffer, lineColor: grey, tolerance: 60,
                                         backgroundColor: page)
        XCTAssertEqual(gated.bits, loose.bits)
    }

    // MARK: - And a neutral pixel is nobody's ink

    /// A grey pixel is not ink of a coloured line, however near the distance
    /// metric claims it is.
    ///
    /// No threshold tuning reaches this: mid-grey genuinely *is* nearer a
    /// mid-green than the white page is — 41.3 against 101 under this metric,
    /// and 74.8 against 174.9 in plain RGB — so the background gate agrees with
    /// the distance gate that the pixel belongs to the curve. It is the absence
    /// of hue, not any distance, that identifies it. The end-to-end test below
    /// is how this was found: the anti-aliased rim of the chart's black axis was
    /// being read as green and area digitising reported a point sitting on the
    /// axis at the bottom-left corner.
    func testNeutralPixelsAreNotInkOfAColouredLine() {
        let midGrey = RGB8(r: 149, g: 149, b: 149)
        let loose = ForegroundMask.build(from: strip([midGrey]), lineColor: green, tolerance: 60,
                                         backgroundColor: page, hueTolerance: gateOff)
        XCTAssertEqual(loose.foregroundCount, 1, "前提:中灰确实落在绿色的容差内")
        let gated = ForegroundMask.build(from: strip([midGrey]), lineColor: green, tolerance: 60,
                                         backgroundColor: page)
        XCTAssertEqual(gated.foregroundCount, 0)
    }

    // MARK: - End to end: the reported chart

    /// Two saturated curves, a soft-edged stroke, area digitising — the whole
    /// path the user took, on a chart built to the same numbers as the figure
    /// they sent.
    ///
    /// What is asserted is the *result*, not the mask: no extracted point may sit
    /// on the orange curve. The failure mode is a point landing dead centre on the
    /// neighbouring stroke — the leaked rim pixels of a column are separated by
    /// less than the run-breaking gap, so they merge into one run whose centroid
    /// is the middle of the stroke that was never meant to be read.
    func testAreaDigitizeStaysOffTheOtherCurveOnASoftStrokedChart() throws {
        let chart = SyntheticChart.renderMulti(
            size: (width: 900, height: 640),
            functions: [{ 1.0 + 0.5 * sin(0.5 * $0 + 0.3) },
                        { 4.0 + 0.4 * sin(0.5 * $0 + 2.0) }],
            colors: [green, orange],
            lineWidth: 9)
        let buffer = softened(chart.buffer)
        let rect = PixelRect(x0: 81, y0: 41, x1: 858, y1: 578)

        func extracted(hueTolerance: Double) -> [PixelPoint] {
            let mask = ForegroundMask.build(from: buffer, lineColor: green, tolerance: 60,
                                            backgroundColor: chart.backgroundColor,
                                            hueTolerance: hueTolerance)
            return AreaDigitizer.digitize(mask: mask, rect: rect, dx: 18)
        }

        let loose = extracted(hueTolerance: gateOff)
        let gated = extracted(hueTolerance: ForegroundMask.defaultHueTolerance)
        let onOrangeLoose = onCurve(loose, chart.series[1].pixels, within: 4)
        let onOrangeGated = onCurve(gated, chart.series[1].pixels, within: 4)

        // The scenario first, so a fixture that stopped reproducing the bug cannot
        // quietly turn the real assertion below into a tautology.
        XCTAssertGreaterThan(onOrangeLoose, 0,
                             "关掉闸门后这个场景没有复现混色 —— 测试图已经不是报告里那张图了")
        XCTAssertEqual(onOrangeGated, 0, "\(onOrangeGated) 个点落在橙曲线上")

        // And the green curve is still read, in full and in place: a gate that
        // "fixes" the leak by emptying the mask would satisfy the line above.
        XCTAssertGreaterThan(gated.count, 20, "绿曲线自己也取不到点了")
        XCTAssertEqual(onCurve(gated, chart.series[0].pixels, within: 3), gated.count,
                       "取到的点偏离了绿曲线")
    }
}
