import XCTest
import GDCore

/// B-1 网格线去除。夹具是「曲线 + 10×10 网格」的合成图,网格与曲线**同色** ——
/// 那是本功能唯一有意义的场景:网格换个颜色的话,距离与色相两道闸门早就把它
/// 挡住了,几何这一步再准也证明不了什么。
final class GridLineRemoverTests: XCTestCase {

    // MARK: - Helpers

    /// 一列(或一行)网格线上、落在掩膜内的像素数。
    private func ink(onGridLines lines: [Int], of mask: ForegroundMask,
                     isColumn: Bool) -> Int {
        var count = 0
        for line in lines {
            let span = isColumn ? mask.height : mask.width
            for j in 0..<span {
                let x = isColumn ? line : j
                let y = isColumn ? j : line
                let near = 0...0
                for d in near where mask.isForeground(x: x + (isColumn ? d : 0),
                                                      y: y + (isColumn ? 0 : d)) {
                    count += 1
                }
            }
        }
        return count
    }

    /// 曲线真值上有多少比例的点,在掩膜里半径 2px 内还有墨迹。
    private func curveRetention(_ chart: SyntheticChart.Chart, mask: ForegroundMask) -> Double {
        var kept = 0
        var total = 0
        for (i, p) in chart.curvePixels.enumerated() where i % 10 == 0 {
            total += 1
            let cx = Int(p.x.rounded()), cy = Int(p.y.rounded())
            var found = false
            for dy in -2...2 where !found {
                for dx in -2...2 where !found {
                    let x = cx + dx, y = cy + dy
                    if x >= 0, x < mask.width, y >= 0, y < mask.height,
                       mask.isForeground(x: x, y: y) { found = true }
                }
            }
            if found { kept += 1 }
        }
        return total == 0 ? 0 : Double(kept) / Double(total)
    }

    // MARK: - Tests

    /// 主用例:同色 10×10 网格,清掉 ≥95%,曲线保留 ≥95%。
    func testRemovesSameColourGridAndKeepsTheCurve() throws {
        let chart = SyntheticChart.render(gridColumns: 10, gridRows: 10, gridLineWidth: 1)
        XCTAssertEqual(chart.gridColumns.count, 10)
        XCTAssertEqual(chart.gridRows.count, 10)

        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        let gridBefore = ink(onGridLines: chart.gridColumns, of: mask, isColumn: true)
            + ink(onGridLines: chart.gridRows, of: mask, isColumn: false)
        XCTAssertGreaterThan(gridBefore, 0, "夹具里没有网格墨迹,测试没有意义")

        let (cleaned, outcome) = GridLineRemover.remove(from: mask)
        let gridAfter = ink(onGridLines: chart.gridColumns, of: cleaned, isColumn: true)
            + ink(onGridLines: chart.gridRows, of: cleaned, isColumn: false)

        let removedShare = 1 - Double(gridAfter) / Double(gridBefore)
        XCTAssertGreaterThanOrEqual(removedShare, 0.95,
                                    "网格只清掉了 \(String(format: "%.1f", removedShare * 100))%")
        XCTAssertEqual(outcome.columns.count, 10, "列数不对:\(outcome.columns)")
        XCTAssertEqual(outcome.rows.count, 10, "行数不对:\(outcome.rows)")

        let retention = curveRetention(chart, mask: cleaned)
        XCTAssertGreaterThanOrEqual(retention, 0.95,
                                    "曲线只留下 \(String(format: "%.1f", retention * 100))%")
    }

    /// 没有网格的图必须原样不动 —— 否则这一步会在普通图上啃掉数据。
    func testLeavesAGridlessChartUntouched() {
        let chart = SyntheticChart.render()
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        let (cleaned, outcome) = GridLineRemover.remove(from: mask)
        XCTAssertTrue(outcome.isEmpty, "无网格的图却动了:\(outcome.columns) / \(outcome.rows)")
        XCTAssertEqual(cleaned.bits, mask.bits)
    }

    /// 清掉的**恰好**是那些网格线,一条不多一条不少。
    ///
    /// 比"网格被清掉、曲线留下来"更严:它把"顺手多清了一列"也钉住 —— 多清的那一列
    /// 在真实图上就是一段凭空消失的数据,而且没有任何症状。(坐标轴在这里不会进
    /// 候选:它是黑色,掩膜只含曲线色 —— 闸门先一步挡住了它。)
    func testRemovesExactlyTheGridLines() {
        let chart = SyntheticChart.render(gridColumns: 10, gridRows: 10)
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        let (_, outcome) = GridLineRemover.remove(from: mask)
        XCTAssertEqual(outcome.columns, chart.gridColumns)
        XCTAssertEqual(outcome.rows, chart.gridRows)
    }

    /// **安全阀**:没有网格的图上,一条贯穿全图的笔直数据线必须留下。
    ///
    /// 判据里唯一挡住它的是「至少要成族」:`minLines = 3` 之下,孤零零一条长直线
    /// 无论多长多直都不动。去掉这一条,任何平直的数据段都会被当成网格啃掉。
    func testKeepsAStraightDataLineWhenThereIsNoGrid() {
        // 一条水平直线(常函数)加坐标轴:两条长直线,不同间距,不成族。
        let chart = SyntheticChart.render(function: { _ in 3.0 })
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        let (cleaned, outcome) = GridLineRemover.remove(from: mask)
        XCTAssertTrue(outcome.isEmpty, "无网格的图上动了直线:\(outcome.rows) / \(outcome.columns)")

        // 直线上取中段一点,必须还在。
        let mid = chart.curvePixels[chart.curvePixels.count / 2]
        let cx = Int(mid.x.rounded()), cy = Int(mid.y.rounded())
        var kept = false
        for dy in -2...2 where !kept {
            for dx in -2...2 where !kept {
                if cleaned.isForeground(x: cx + dx, y: cy + dy) { kept = true }
            }
        }
        XCTAssertTrue(kept, "笔直的数据线被当成网格清掉了")
    }

    /// 曲线与网格线**交叉处**的像素必须留下 —— 清整列会把曲线在十个地方割断。
    func testKeepsCurveWhereItCrossesAGridLine() {
        let chart = SyntheticChart.render(gridColumns: 10, gridRows: 0, gridLineWidth: 1)
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        let (cleaned, _) = GridLineRemover.remove(from: mask)

        // 对每条网格列,找曲线上离它最近的真值点,检查该点邻域还有墨迹。
        var checked = 0
        for column in chart.gridColumns {
            var nearest: PixelPoint?
            var best = Double.infinity
            for p in chart.curvePixels {
                let d = abs(p.x - Double(column))
                if d < best { best = d; nearest = p }
            }
            guard let p = nearest, best <= 3 else { continue }
            checked += 1
            let cx = Int(p.x.rounded()), cy = Int(p.y.rounded())
            var found = false
            for dy in -2...2 where !found {
                for dx in -2...2 where !found {
                    let x = cx + dx, y = cy + dy
                    if x >= 0, x < cleaned.width, y >= 0, y < cleaned.height,
                       cleaned.isForeground(x: x, y: y) { found = true }
                }
            }
            XCTAssertTrue(found, "网格列 \(column) 处的曲线被一起清掉了")
        }
        XCTAssertGreaterThan(checked, 5, "交叉点样本太少(\(checked)),断言没验到什么")
    }

    /// 网格换个颜色(距离/色相闸门已经能挡住)时,几何这一步不该误伤任何东西 ——
    /// 它看到的应当是一个"没有网格"的掩膜。
    func testDoesNothingWhenTheGridWasAlreadyGatedOut() {
        let gridGrey = RGB8(r: 205, g: 205, b: 205)
        let chart = SyntheticChart.render(gridColumns: 10, gridRows: 10,
                                          gridColor: gridGrey, gridLineWidth: 1)
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor,
                                        tolerance: 60)
        let (cleaned, outcome) = GridLineRemover.remove(from: mask)
        XCTAssertTrue(outcome.isEmpty,
                      "浅灰网格已被闸门挡住,几何这一步却又动了它:\(outcome.columns)")
        XCTAssertEqual(cleaned.bits, mask.bits)
    }
}
