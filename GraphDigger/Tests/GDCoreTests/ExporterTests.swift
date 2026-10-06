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

    // MARK: - 小数分隔符 (FR-11)

    /// The default is the whole of the backward-compatibility promise: every
    /// caller that existed before this feature passes no separator, so `.dot`
    /// has to stay the answer and the bytes have to stay byte-identical.
    func testDefaultSeparatorIsStillTheDot() throws {
        let text = try Exporter.text(for: [makeLine()], calibration: calibration,
                                     format: .csv)
        XCTAssertEqual(text, "x,y\n0,0\n5.000000,2.500000\n10.000000,5.000000\n")
        XCTAssertFalse(text.contains(";"))
    }

    /// The invariant the whole feature rests on.
    ///
    /// If a case ever made the column separator and the decimal separator the
    /// same character, every CSV it wrote would split its own numbers and no
    /// assertion about field counts would save it — the two readings of
    /// `1,5,2,5` are indistinguishable in the text.
    func testTheColumnSeparatorIsNeverTheDecimalSeparator() {
        for separator in DecimalSeparator.allCases {
            XCTAssertNotEqual(separator.csvSeparator, separator.character, "\(separator)")
        }
    }

    func testCommaDecimalSwapsTheCSVHeaderSeparatorToo() throws {
        let text = try Exporter.text(for: [makeLine("A")], calibration: calibration,
                                     format: .csv, decimalSeparator: .comma)
        XCTAssertEqual(text.split(separator: "\n").first.map(String.init), "x;y")
    }

    /// One curve, comma decimals: the commas in the file are all decimal points
    /// and the fields are still fields.
    func testCommaDecimalKeepsTheFieldCountInASingleCurveCSV() throws {
        let text = try Exporter.text(for: [makeLine()], calibration: calibration,
                                     format: .csv, decimalSeparator: .comma)
        XCTAssertEqual(text, "x;y\n0;0\n5,000000;2,500000\n10,000000;5,000000\n")
        // The property a parser depends on, asserted independently of the string
        // above: every row is two fields, and every field is a number once the
        // decimal comma is put back.
        for row in text.split(separator: "\n").dropFirst() {
            let cells = row.split(separator: ";", omittingEmptySubsequences: false)
            XCTAssertEqual(cells.count, 2, "行不是两列: \(row)")
            for cell in cells {
                XCTAssertNotNil(Double(cell.replacingOccurrences(of: ",", with: ".")),
                                "\(cell) 不是数字")
            }
        }
    }

    /// Several curves, comma decimals. The wide table is where a wrong separator
    /// hurts most: four columns collapsing into one is silent in Excel.
    func testCommaDecimalKeepsTheWideTableWide() throws {
        let short = CurveLine(name: "short", color: RGB8(r: 0, g: 0, b: 0),
                              points: [PixelPoint(x: 100, y: 600)])            // -> (0, 0)
        let long = makeLine("long")                                             // -> 3 points
        let comma = try Exporter.text(for: [short, long], calibration: calibration,
                                      format: .csv, decimalSeparator: .comma)
        let rows = comma.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: ";", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(rows.first, ["x1", "y1", "x2", "y2"])
        XCTAssertEqual(rows.dropLast().count, 4)
        XCTAssertEqual(rows[1], ["0", "0", "0", "0"])
        // The hole stays a hole: the short curve's cells are empty, so the long
        // curve's values stay in columns 3 and 4 rather than sliding left.
        XCTAssertEqual(rows[3], ["", "", "10,000000", "5,000000"])
    }

    /// The two files are the same file, differently spelt — which is the only
    /// honest way to say "the setting changed nothing but the spelling".
    ///
    /// Comparing field by field rather than by a blind string substitution: a
    /// substitution is what the implementation does, so asserting it would only
    /// be asserting the implementation back at itself.
    func testTheTwoSeparatorsProduceTheSameTable() throws {
        let lines = [makeLine("A"), makeLine("B")]
        let dot = try Exporter.text(for: lines, calibration: calibration, format: .csv)
        let comma = try Exporter.text(for: lines, calibration: calibration,
                                      format: .csv, decimalSeparator: .comma)
        let dotRows = dot.split(separator: "\n", omittingEmptySubsequences: false)
        let commaRows = comma.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(dotRows.count, commaRows.count)

        var sameTable = true
        for (d, c) in zip(dotRows, commaRows) {
            let dCells = d.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let cCells = c.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            if dCells.count != cCells.count { sameTable = false; break }
            for (left, right) in zip(dCells, cCells)
            where left != right.replacingOccurrences(of: ",", with: ".") {
                sameTable = false
            }
        }
        XCTAssertTrue(sameTable, "两种分隔符下的表格内容不一致:\n\(dot)\n---\n\(comma)")
    }

    /// A tab is not a decimal point, so TSV needs only the numbers' spelling —
    /// and it is the format the clipboard uses, so it is the one that gets
    /// pasted into the Excel this setting exists for.
    func testCommaDecimalAppliesToTSVWithoutTouchingItsTabs() throws {
        let text = try Exporter.text(for: [makeLine()], calibration: calibration,
                                     format: .tsv, decimalSeparator: .comma)
        XCTAssertEqual(text, "x\ty\n0\t0\n5,000000\t2,500000\n10,000000\t5,000000\n")
    }

    /// Neither is a space — and the labelled blocks survive, because TXT is the
    /// format read by eye and its layout is not what this setting is about.
    func testCommaDecimalAppliesToTXTBlocks() throws {
        let text = try Exporter.text(for: [makeLine("A"), makeLine("B")],
                                     calibration: calibration, format: .txt,
                                     decimalSeparator: .comma)
        XCTAssertTrue(text.contains("# A"))
        XCTAssertTrue(text.contains("5,000000 2,500000"))
        XCTAssertFalse(text.contains("."), "TXT 里不该还有句点小数:\n\(text)")
    }

    /// Big numbers leave as `1,234567e+07`, not `1,234567e+07` mixed with
    /// `1.234567e+07` further down: a file whose notation switches halfway is
    /// the kind that reads fine until it does not.
    func testCommaDecimalReachesScientificNotation() throws {
        let wide = CalibrationMap(
            x: AxisCalibration(pixelMin: 0, valueMin: 0, pixelMax: 100, valueMax: 5e7),
            y: AxisCalibration(pixelMin: 0, valueMin: 0, pixelMax: 100, valueMax: 1))
        let line = CurveLine(name: "big", color: RGB8(r: 0, g: 0, b: 0),
                             points: [PixelPoint(x: 100, y: 0)])
        let text = try Exporter.text(for: [line], calibration: wide,
                                     format: .csv, includeHeader: false,
                                     decimalSeparator: .comma)
        XCTAssertTrue(text.contains("5,000000e+07"), "科学计数法没跟着换:\(text)")
        XCTAssertFalse(text.contains("."), "还有句点:\(text)")
    }

    /// The machine formats ignore the setting *entirely* — byte-identical output
    /// either way.
    ///
    /// Not a nicety: `x="1,5"` is not a number to an XML parser, `10\n1,5\n` is
    /// two tokens to a CAD reader, and a workbook holds real numbers whose
    /// display is the reader's own business. Their grammars are fixed, so the
    /// setting has no business reaching them.
    func testMachineFormatsIgnoreTheSeparatorSettingEntirely() throws {
        for format in [ExportFormat.xml, .dxf, .eps, .xlsx] {
            let dot = try Exporter.data(for: [makeLine()], calibration: calibration,
                                        format: format, decimalSeparator: .dot)
            let comma = try Exporter.data(for: [makeLine()], calibration: calibration,
                                          format: format, decimalSeparator: .comma)
            XCTAssertEqual(dot, comma, "\(format) 的输出不该随小数分隔符变")
            // …and the assertion is not vacuous: these formats do carry fractions.
            XCTAssertTrue(dot.contains(UInt8(ascii: ".")),
                          "\(format) 里一个小数都没有,这条断言等于没写")
        }
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
