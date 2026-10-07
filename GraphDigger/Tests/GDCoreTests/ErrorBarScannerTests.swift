import XCTest
import GDCore

/// B-2 误差棒提取。
///
/// 夹具是「散点 + 每点一根带上下横杠的竖棒」,真值逐点给出。**认的是横杠,不是
/// 竖线** —— 竖线毫无特征(曲线陡坡、刻度线、网格线都是),只有"细笔画走到头
/// 横向铺开一段"才是误差棒。所以"不许误报"的几条比"量得准"更重要。
final class ErrorBarScannerTests: XCTestCase {

    private func mask(of chart: SyntheticChart.ErrorBarChart) -> ForegroundMask {
        ForegroundMask.build(from: chart.buffer, lineColor: chart.lineColor, tolerance: 60)
    }

    /// 主用例:对称误差,逐个点量出的上下误差都要在 1.5px 内。
    func testMeasuresSymmetricErrorBars() {
        let chart = SyntheticChart.renderErrorBars(count: 8)
        let result = ErrorBarScanner.scan(points: chart.points, mask: mask(of: chart))

        XCTAssertEqual(result.found, 8, "8 个点里只找到 \(result.found) 根")
        for (i, offset) in result.offsets.enumerated() {
            guard let offset else {
                XCTFail("第 \(i) 个点没找到误差棒")
                continue
            }
            XCTAssertEqual(offset.up, chart.upPixels[i], accuracy: 1.5,
                           "第 \(i) 个点的上误差")
            XCTAssertEqual(offset.down, chart.downPixels[i], accuracy: 1.5,
                           "第 \(i) 个点的下误差")
        }
    }

    /// 不对称误差:上下各自量,不许被平均成一个值。
    ///
    /// 对称只是常见情形,不是定义 —— 合成一个 ±值就把信息丢了,而"上 +1σ /
    /// 下 −2σ"在实验数据里常见得很。
    func testKeepsAsymmetricBarsApart() {
        let chart = SyntheticChart.renderErrorBars(count: 6,
                                                   up: { _ in 34 },
                                                   down: { _ in 12 })
        let result = ErrorBarScanner.scan(points: chart.points, mask: mask(of: chart))
        XCTAssertEqual(result.found, 6)
        for (i, offset) in result.offsets.enumerated() {
            guard let offset else { XCTFail("第 \(i) 个点没找到"); continue }
            XCTAssertEqual(offset.up, 34, accuracy: 1.5, "上误差被抹平了")
            XCTAssertEqual(offset.down, 12, accuracy: 1.5, "下误差被抹平了")
            XCTAssertGreaterThan(offset.up - offset.down, 18,
                                 "上下被当成了一个值")
        }
    }

    /// **不许误报**:同一张图去掉棒、只留散点,一个误差棒都不该报出来。
    ///
    /// 这是最要紧的一条:误报会让用户拿到一组看起来正常的假误差值,而他不会
    /// 一个个去核对。对照图与主用例逐像素相同,只少了棒。
    func testReportsNothingOnAPlainScatter() {
        let chart = SyntheticChart.renderErrorBars(count: 8, withErrorBars: false)
        let result = ErrorBarScanner.scan(points: chart.points, mask: mask(of: chart))
        XCTAssertEqual(result.found, 0, "纯散点图上报出了 \(result.found) 根误差棒")
        XCTAssertTrue(result.offsets.allSatisfy { $0 == nil })
    }

    /// **不许误报**:点在曲线上时,两侧顺着曲线走会走很远,但曲线没有横杠,
    /// 所以一个都不该报。(把散点的位置直接拿来当"已取到的点",它们周围只有
    /// 曲线与坐标轴。)
    func testReportsNothingOnACurve() {
        let chart = SyntheticChart.render()
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor, tolerance: 60)
        // 沿曲线每隔一段取一个点,当作"已取到的点"。
        let probes = stride(from: 40, to: chart.curvePixels.count - 40, by: 120)
            .map { chart.curvePixels[$0] }
        let result = ErrorBarScanner.scan(points: probes, mask: mask)
        XCTAssertEqual(result.found, 0, "曲线上的 \(result.found) 个点被误报成误差棒")
    }

    /// 棒太长(超过扫描上限)时不报,而不是报一个被截断的假值。
    ///
    /// 上限的作用是防止"顺着曲线一直走下去":走到了上限还没遇到横杠,答案该是
    /// "没有",不是"就是上限那么长"。
    func testDoesNotReportAnOverlongStem() {
        let chart = SyntheticChart.renderErrorBars(count: 4, up: { _ in 200 },
                                                   down: { _ in 200 })
        let result = ErrorBarScanner.scan(points: chart.points, mask: mask(of: chart))
        XCTAssertEqual(result.found, 0, "超长棒被报成了误差棒")
    }

    /// 逐点给不同长度,验证"一对一到人"没错位。
    func testKeepsOffsetsAlignedWithTheirPoints() {
        let lengths: [Double] = [10, 22, 34, 18, 40, 26]
        let chart = SyntheticChart.renderErrorBars(count: lengths.count,
                                                   up: { lengths[$0] },
                                                   down: { lengths[$0] })
        let result = ErrorBarScanner.scan(points: chart.points, mask: mask(of: chart))
        XCTAssertEqual(result.found, lengths.count)
        for (i, expected) in lengths.enumerated() {
            guard let offset = result.offsets[i] else { XCTFail("第 \(i) 个没找到"); continue }
            XCTAssertEqual(offset.up, expected, accuracy: 1.5, "第 \(i) 个错位了")
        }
    }
}
