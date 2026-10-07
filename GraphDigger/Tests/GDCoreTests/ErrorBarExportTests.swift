import XCTest
import GDCore

/// B-2 误差棒的导出口径。
///
/// 误差在模型里存的是**像素**(与点一致),导出时才按曲线自己的标定换算成数值 ——
/// 所以这里要验的是"换算真的发生了",而不是"数还是那几个数"。
final class ErrorBarExportTests: XCTestCase {

    /// 一条曲线:y 轴 560px(下,值 0)→ 100px(上,值 5),即 460px = 5 个单位。
    private func chart() -> (line: CurveLine, map: CalibrationMap) {
        var line = CurveLine(name: "样品 A", color: RGB8(r: 20, g: 20, b: 20))
        line.points = [PixelPoint(x: 100, y: 300), PixelPoint(x: 200, y: 200)]
        line.errorBars = [ErrorBarOffset(up: 28, down: 14), nil]
        let map = CalibrationMap.linear(xMin: 0, yMin: 0, xMax: 10, yMax: 5,
                                        pixelXMin: 80, pixelYMin: 560,
                                        pixelXMax: 700, pixelYMax: 100)
        return (line, map)
    }

    func testCSVGainsTwoColumnsInDataUnits() throws {
        let (line, map) = chart()
        let csv = try Exporter.text(for: [line], calibration: map, format: .csv)
        let rows = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(rows[0], "x,y,yErrLow,yErrHigh")

        // 460px = 5 个单位 → 14px = 0.1521…,28px = 0.3043…
        // 向上的棒(pixel y 变小 = 数值变大)落在 yErrHigh 一列,向下落在 yErrLow ——
        // 两列是按**数值方向**分的高低,不是按屏幕上下分的。
        let first = rows[1].split(separator: ",").map(String.init)
        XCTAssertEqual(first.count, 4, "第一行不是四列:\(rows[1])")
        XCTAssertEqual(Double(first[2]) ?? -1, 14.0 * 5.0 / 460.0, accuracy: 0.005,
                       "下误差没按标定换算")
        XCTAssertEqual(Double(first[3]) ?? -1, 28.0 * 5.0 / 460.0, accuracy: 0.005,
                       "上误差没按标定换算")

        // 第二个点没有棒:两列留空,而不是写 0 —— 0 是一个测量结果。
        let second = rows[2].split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertEqual(second.count, 4)
        XCTAssertEqual(second[2], "", "没有棒的点被写成了 \(second[2])")
        XCTAssertEqual(second[3], "")
    }

    /// 全都没有误差数据时,导出的字节必须与从前**一模一样** —— 两列。
    ///
    /// 这条是回归保护:多两列会让所有既有的解析脚本(以及 Excel 里的公式)错位,
    /// 而那发生在"根本没用到误差棒"的工程上是最没道理的。
    func testWithoutErrorBarsTheLayoutIsUnchanged() throws {
        var (line, map) = chart()
        line.errorBars = nil
        let csv = try Exporter.text(for: [line], calibration: map, format: .csv)
        XCTAssertEqual(csv.split(separator: "\n")[0], "x,y")
        XCTAssertEqual(csv.split(separator: "\n")[1].split(separator: ",").count, 2)

        // 显式给一组长全为 nil 的误差(扫过但一个都没找到)也不该多列。
        line.errorBars = [nil, nil]
        let scanned = try Exporter.text(for: [line], calibration: map, format: .csv)
        XCTAssertEqual(scanned, csv, "扫过但没找到棒,列却变了")
    }

    /// 多曲线的宽表:只有带误差的那条多两列,其余保持两列。
    func testWideTableGivesErrorColumnsOnlyToTheCurveThatHasThem() throws {
        var (withBars, map) = chart()
        var plain = CurveLine(name: "样品 B", color: RGB8(r: 20, g: 20, b: 20))
        plain.points = [PixelPoint(x: 110, y: 310), PixelPoint(x: 210, y: 210)]
        let csv = try Exporter.text(for: [withBars, plain], calibration: map, format: .csv)
        let header = csv.split(separator: "\n")[0]
        XCTAssertEqual(header, "x1,y1,yErrLow1,yErrHigh1,x2,y2")
        _ = withBars
    }

    /// XLSX 同样多两列,且表头一致。
    ///
    /// 条目是**存储**(不压缩)写的 —— 见 `ZIPArchive` 的说明 —— 所以直接在字节里
    /// 找表头与数值是可靠的,不用再写一个读包器。
    func testXLSXCarriesTheSameColumns() throws {
        let (line, map) = chart()
        let data = try Exporter.data(for: [line], calibration: map, format: .xlsx)
        for expected in ["yErrLow", "yErrHigh", "0.304", "0.152"] {
            XCTAssertTrue(data.range(of: Data(expected.utf8)) != nil,
                          "工作表里没有 \(expected)")
        }
    }

    /// 点一变(这里删掉一个点),按位置对齐的误差必须整组作废,而不是错位。
    func testEditingPointsDropsTheAlignment() {
        var (line, _) = chart()
        XCTAssertTrue(line.hasErrorBars)
        line.points.removeLast()
        XCTAssertNil(line.errorBars, "点被删掉后误差还留着 —— 它们会安到错误的点上")
        XCTAssertFalse(line.hasErrorBars)
    }

    /// **移动**一个点(与拖动等价)同样要作废,哪怕点数没变。
    ///
    /// 这是复核时抓到的一个真 bug:原先的不变量只查长度,而拖动改的是坐标 ——
    /// 于是误差棒留着不动。可它量的是**图上那根墨迹**到点的距离,点一挪,
    /// 那个数就不再成立,而数字看上去完全正常。
    func testMovingAPointAlsoDropsTheBars() {
        var (line, _) = chart()
        XCTAssertTrue(line.hasErrorBars)
        line.points[0] = PixelPoint(x: line.points[0].x + 12, y: line.points[0].y)
        XCTAssertNil(line.errorBars, "点被移动后误差还留着 —— 那些值已不对应图上那根棒")
    }

    /// 写入同一批点的坐标(内容没变)不该作废 —— 否则每次重绘都可能悄悄丢掉误差。
    func testWritingTheSamePointsKeepsTheBars() {
        var (line, _) = chart()
        let unchanged = line.points
        line.points = unchanged
        XCTAssertTrue(line.hasErrorBars, "坐标内容没变,误差却被丢掉了")
    }
}
