import XCTest
import GDCore

final class ExporterTests: XCTestCase {

    private let calibration = CalibrationMap(
        x: AxisCalibration(pixelMin: 100, valueMin: 0, pixelMax: 900, valueMax: 10),
        y: AxisCalibration(pixelMin: 600, valueMin: 0, pixelMax: 100, valueMax: 5))

    private func makeLine(_ name: String = "Curve 1") -> CurveLine {
        CurveLine(name: name, color: RGB8(r: 200, g: 40, b: 40),
                  points: [PixelPoint(x: 100, y: 600),   // -> (0, 0)
                           PixelPoint(x: 500, y: 350),   // -> (5, 2.5)
                           PixelPoint(x: 900, y: 100)])  // -> (10, 5)
    }

    func testCSVValuesMapThroughCalibration() throws {
        let text = try Exporter.text(for: [makeLine()], calibration: calibration, format: .csv)
        let rows = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.first, "x,y")
        // Exact zero prints as "0"; other values keep six decimals.
        XCTAssertEqual(rows[1], "0,0")
        XCTAssertEqual(rows[2], "5.000000,2.500000")
        XCTAssertEqual(rows[3], "10.000000,5.000000")
    }

    func testTSVUsesTabsLikeExcelExpects() throws {
        let text = try Exporter.text(for: [makeLine()], calibration: calibration,
                                     format: .tsv, includeHeader: false)
        XCTAssertEqual(text.split(separator: "\n").first.map(String.init), "0\t0")
    }

    func testHeaderOmittedWhenAsked() throws {
        let text = try Exporter.text(for: [makeLine()], calibration: calibration,
                                     format: .csv, includeHeader: false)
        XCTAssertFalse(text.contains("x,y"))
        XCTAssertEqual(text.split(separator: "\n").count, 3)
    }

    /// Several curves into CSV: **one wide table**, not named blocks.
    ///
    /// This replaces a test that asserted the blocks (`# A` / `# B`). The layout
    /// was changed on purpose, because a `#` comment line is not part of CSV:
    /// pandas raises, and Excel puts it in column A as a data row — both
    /// silently wrong. The names live in the header row now.
    func testMultipleCurvesInCSVAreOneParseableTable() throws {
        let text = try Exporter.text(for: [makeLine("A"), makeLine("B")],
                                     calibration: calibration, format: .csv)
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(rows.first, "x1,y1,x2,y2")

        // Every line the same width, and every cell of a *data* row a number.
        // This is the property a parser depends on. The header is skipped on
        // purpose — it is names, which is exactly what makes it a header.
        for row in rows.dropFirst().dropLast() {
            XCTAssertEqual(row.split(separator: ",", omittingEmptySubsequences: false).count, 4,
                           "行不是四列: \(row)")
            XCTAssertFalse(row.hasPrefix("#"), "注释行不是 CSV: \(row)")
            for cell in row.split(separator: ",") {
                XCTAssertNotNil(Double(cell), "\(cell) 不是数字")
            }
        }
    }

    /// …and the columns really do pair each curve with its own values.
    ///
    /// A wide table that put B's y in A's column would pass every check above.
    func testTheWideTableKeepsEachCurveInItsOwnColumns() throws {
        let short = CurveLine(name: "short", color: RGB8(r: 0, g: 0, b: 0),
                              points: [PixelPoint(x: 100, y: 600)])            // -> (0, 0)
        let long = makeLine("long")                                             // -> 3 points
        let text = try Exporter.text(for: [short, long],
                                     calibration: calibration, format: .csv)
        // `omittingEmptySubsequences: false` throughout: the empty cells are the
        // thing under test, and the default would swallow them and make a
        // two-column row look like a four-column one.
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }

        // 表头 + 最长那条曲线的 3 行;末尾还有一个空串,是正文末尾那个换行。
        XCTAssertEqual(rows.dropLast().count, 4)
        XCTAssertEqual(rows[1], ["0", "0", "0", "0"], "两边的第一个点都在第一行")
        // The short curve has run out: its cells are empty, and the long curve's
        // values stay in columns 3 and 4 rather than sliding left.
        XCTAssertEqual(rows[3], ["", "", "10.000000", "5.000000"])
    }

    /// TXT is for reading, so it keeps the labelled blocks.
    func testMultipleCurvesInTXTStayLabelledBlocks() throws {
        let text = try Exporter.text(for: [makeLine("A"), makeLine("B")],
                                     calibration: calibration, format: .txt)
        XCTAssertTrue(text.contains("# A"))
        XCTAssertTrue(text.contains("# B"))
    }

    func testMissingCalibrationThrows() {
        XCTAssertThrowsError(try Exporter.text(for: [makeLine()],
                                               calibration: nil, format: .csv)) { error in
            XCTAssertEqual(error as? ExportError, .calibrationMissing)
        }
    }

    func testNoPointsThrows() {
        let empty = CurveLine(name: "empty", color: RGB8(r: 0, g: 0, b: 0), points: [])
        XCTAssertThrowsError(try Exporter.text(for: [empty],
                                               calibration: calibration, format: .csv)) { error in
            XCTAssertEqual(error as? ExportError, .noPoints)
        }
    }

    func testXMLIsWellFormedAndCarriesCalibration() throws {
        let text = try Exporter.text(for: [makeLine()], calibration: calibration, format: .xml)
        let parser = XMLParser(data: Data(text.utf8))
        XCTAssertTrue(parser.parse(), "XML output must be well-formed")
        XCTAssertTrue(text.contains("<axis name=\"x\""))
        XCTAssertTrue(text.contains("logarithmic=\"false\""))
    }

    func testDXFHasPolylinePerCurve() throws {
        let text = try Exporter.text(for: [makeLine("A"), makeLine("B")],
                                     calibration: calibration, format: .dxf)
        XCTAssertTrue(text.hasPrefix("0\nSECTION"))
        XCTAssertTrue(text.hasSuffix("0\nEOF\n"))
        XCTAssertEqual(text.components(separatedBy: "POLYLINE").count - 1, 2)
        XCTAssertEqual(text.components(separatedBy: "VERTEX").count - 1, 6)
    }

    func testEPSHasHeaderAndOneStrokePerCurve() throws {
        let text = try Exporter.text(for: [makeLine()], calibration: calibration, format: .eps)
        XCTAssertTrue(text.hasPrefix("%!PS-Adobe-3.0 EPSF-3.0"))
        XCTAssertTrue(text.contains("%%BoundingBox"))
        XCTAssertTrue(text.contains("moveto"))
        XCTAssertTrue(text.contains("lineto"))
        XCTAssertTrue(text.hasSuffix("%%EOF\n"))
    }

    func testLargeMagnitudesSwitchToScientificNotation() throws {
        let wide = CalibrationMap(
            x: AxisCalibration(pixelMin: 0, valueMin: 0, pixelMax: 100, valueMax: 5e7),
            y: AxisCalibration(pixelMin: 0, valueMin: 0, pixelMax: 100, valueMax: 1))
        let line = CurveLine(name: "big", color: RGB8(r: 0, g: 0, b: 0),
                             points: [PixelPoint(x: 100, y: 0)])
        let text = try Exporter.text(for: [line], calibration: wide,
                                     format: .csv, includeHeader: false)
        XCTAssertTrue(text.contains("e+"), "expected scientific notation, got \(text)")
    }
}

final class ProjectStateTests: XCTestCase {

    func testAppendCreatesActiveLineOnDemand() {
        var state = ProjectState()
        XCTAssertNil(state.activeLine)
        state.append(points: [PixelPoint(x: 1, y: 2)], usingDefaultColor: RGB8(r: 1, g: 2, b: 3))
        XCTAssertEqual(state.lines.count, 1)
        XCTAssertEqual(state.activeLine?.points.count, 1)
    }

    func testAppendAccumulatesIntoTheActiveLine() {
        var state = ProjectState()
        let color = RGB8(r: 1, g: 2, b: 3)
        state.append(points: [PixelPoint(x: 1, y: 2)], usingDefaultColor: color)
        state.append(points: [PixelPoint(x: 3, y: 4)], usingDefaultColor: color)
        XCTAssertEqual(state.lines.count, 1)
        XCTAssertEqual(state.activeLine?.points.count, 2)
    }

    func testRemoveLineRepointsActiveSelection() {
        var state = ProjectState()
        state.append(points: [PixelPoint(x: 1, y: 2)], usingDefaultColor: RGB8(r: 0, g: 0, b: 0))
        let first = state.activeLineID!
        let second = state.addLine(name: "B", color: RGB8(r: 9, g: 9, b: 9))
        state.removeLine(id: second)
        XCTAssertEqual(state.activeLineID, first)
        XCTAssertEqual(state.lines.count, 1)
    }

    func testProjectStateSurvivesJSONRoundTrip() throws {
        var state = ProjectState()
        state.calibration = CalibrationMap(
            x: AxisCalibration(pixelMin: 0, valueMin: 0, pixelMax: 10, valueMax: 1),
            y: AxisCalibration(pixelMin: 10, valueMin: 0, pixelMax: 0, valueMax: 5,
                               isLogarithmic: false))
        state.defaultBackgroundColor = RGB8(r: 250, g: 250, b: 250)
        state.append(points: [PixelPoint(x: 1.5, y: 2.5)], usingDefaultColor: RGB8(r: 1, g: 1, b: 1))
        let id = state.activeLineID!
        state.setLineColor(RGB8(r: 200, g: 40, b: 40), for: id)
        state.setOrder(.ascendingX, for: id)

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(ProjectState.self, from: data)
        XCTAssertEqual(restored, state)
    }
}
