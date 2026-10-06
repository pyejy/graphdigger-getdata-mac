import Foundation

/// Output formats offered by the app. FR-9 of the requirements doc.
public enum ExportFormat: String, CaseIterable, Sendable {
    /// Comma-separated, one row per point.
    case csv
    /// Tab-separated — the format that pastes straight into Excel.
    case tsv
    /// Whitespace-separated plain text.
    case txt
    /// Simple `<point x="" y="">` document.
    case xml
    /// AutoCAD DXF with one POLYLINE per curve.
    case dxf
    /// PostScript, one polyline per curve.
    case eps
    /// SpreadsheetML — a real workbook, one sheet per curve. Binary, so it goes
    /// out through `Exporter.data(for:calibration:format:)` rather than `text`.
    case xlsx

    public var fileExtension: String { rawValue }

    /// Whether the format is text that `Exporter.text` can produce.
    ///
    /// A workbook is a ZIP of XML parts, so "the export as a string" has no
    /// answer for it — and the callers that need to know are exactly the ones
    /// choosing between writing a string and writing bytes.
    public var isText: Bool { self != .xlsx }

    public var displayName: String {
        switch self {
        case .csv: return "CSV (逗号分隔)"
        case .tsv: return "TSV (制表符,可直接粘贴到 Excel)"
        case .txt: return "TXT (空格分隔)"
        case .xml: return "XML"
        case .dxf: return "DXF (AutoCAD)"
        case .eps: return "EPS (PostScript)"
        case .xlsx: return "XLSX (Excel 工作簿,每线一个表)"
        }
    }
}

/// Which character separates a number's whole part from its fraction.
///
/// A *preference*, not a document property: whether `1.5` or `1,5` is the right
/// spelling depends on the spreadsheet at the receiving end and on nothing about
/// the chart, so one project can legitimately go out both ways. A European or
/// partially localised Chinese Excel reads the comma, and a `1.5` handed to one
/// of those arrives as text sitting in a column of its own — which is why the
/// two most-used digitizers both expose this switch.
public enum DecimalSeparator: String, CaseIterable, Sendable {
    /// `1.5` with `,` between columns — the Anglo-American convention, default.
    case dot
    /// `1,5` with `;` between columns — the European convention.
    case comma

    public var character: String {
        switch self {
        case .dot: return "."
        case .comma: return ","
        }
    }

    /// What goes *between* CSV columns.
    ///
    /// It has to move with the decimal separator rather than sit beside it. A
    /// file whose columns are commas and whose decimals are commas cannot be
    /// read back at all: `1,5,2,5` splits two ways and nothing in the text says
    /// which is meant. The semicolon is what a European Excel writes and expects
    /// for exactly this reason, so picking the comma here makes the file *more*
    /// portable, not less.
    ///
    /// TSV and TXT are unaffected — a tab or a space is not a decimal point.
    public var csvSeparator: String {
        switch self {
        case .dot: return ","
        case .comma: return ";"
        }
    }

    public var displayName: String {
        switch self {
        case .dot: return "句点 . —— 1.5"
        case .comma: return "逗号 , —— 1,5"
        }
    }

    public var hint: String {
        switch self {
        case .dot: return "导出 1.5;CSV 的列用逗号分隔。"
        case .comma: return "导出 1,5;CSV 的列改用分号分隔 —— 否则逗号既当小数点又当列边界,文件读不回来。"
        }
    }
}

public enum ExportError: Error, Equatable {
    case calibrationMissing
    case noPoints
    /// Asked for a text rendering of a format that is not text. Unreachable
    /// through the app, which routes binary formats to `Exporter.data`; here so
    /// that `text` fails honestly rather than returning a string that is not the
    /// file the caller asked for.
    case notATextFormat
}

/// Serialises extracted curves. Pure string building — no file I/O, so the
/// clipboard path and the save-panel path share exactly the same output.
public enum Exporter {

    /// - Parameters:
    ///   - lines: curves to write; hidden lines are included (visibility is a
    ///     display concern).
    ///   - calibration: mapping from stored pixel points to chart values.
    ///   - format: target format.
    ///   - includeHeader: emit a column-name row where the format supports it.
    ///   - decimalSeparator: how numbers are spelt in the delimited formats.
    ///     XML, DXF and EPS ignore it — their grammars are fixed, and a CAD
    ///     package or a PostScript interpreter reading `1,5` is reading a
    ///     two-element list. XLSX ignores it too, because its numbers are stored
    ///     as numbers rather than as text.
    public static func text(for lines: [CurveLine],
                            calibration: CalibrationMap?,
                            format: ExportFormat,
                            includeHeader: Bool = true,
                            decimalSeparator: DecimalSeparator = .dot) throws -> String {
        let populated = lines.filter { !$0.points.isEmpty }
        guard !populated.isEmpty else { throw ExportError.noPoints }

        switch format {
        case .csv, .tsv, .txt:
            return try delimited(populated, calibration: calibration,
                                 format: format, includeHeader: includeHeader,
                                 decimalSeparator: decimalSeparator)
        case .xml:
            return try xml(populated, calibration: calibration)
        case .dxf:
            return try dxf(populated, calibration: calibration)
        case .eps:
            return try eps(populated, calibration: calibration)
        case .xlsx:
            throw ExportError.notATextFormat
        }
    }

    /// The bytes to write for any format, text or binary.
    ///
    /// The single entry point for the save panel, so the caller writes `Data`
    /// either way and never has to know which formats happen to be text. Kept
    /// beside `text` rather than replacing it because the clipboard path only
    /// ever wants TSV, and handing it `Data` to then decode would be a round trip
    /// through an encoding nobody chose.
    public static func data(for lines: [CurveLine],
                            calibration: CalibrationMap?,
                            format: ExportFormat,
                            includeHeader: Bool = true,
                            decimalSeparator: DecimalSeparator = .dot) throws -> Data {
        if format == .xlsx {
            // The separator is accepted and dropped on purpose: a workbook holds
            // real numbers, and how the reader's Excel *displays* them is the
            // reader's own locale. Refusing here would make the caller special-case
            // the format, which is the thing this entry point exists to prevent.
            return try XLSXWriter.data(for: lines, calibration: calibration)
        }
        return Data(try text(for: lines, calibration: calibration,
                             format: format, includeHeader: includeHeader,
                             decimalSeparator: decimalSeparator).utf8)
    }

    /// Value for a point, used by the numeric formats.
    private static func value(_ point: PixelPoint,
                              _ calibration: CalibrationMap?) throws -> DataPoint {
        guard let calibration else { throw ExportError.calibrationMissing }
        return try calibration.data(fromPixel: point)
    }

    /// Nearest AutoCAD Color Index for a display colour. Approximate — DXF R12
    /// has no true-colour form — but enough to tell curves apart in CAD.
    private static func aciIndex(for color: RGB8) -> Int {
        let r = Double(color.r), g = Double(color.g), b = Double(color.b)
        // Pure-ish primaries map to the canonical low indices, else fall back to
        // a neutral. Good enough for distinguishing curves.
        if r > 150 && g < 110 && b < 110 { return 1 }   // red
        if g > 130 && r < 120 && b < 120 { return 3 }   // green
        if b > 150 && r < 120 && g < 140 { return 5 }   // blue
        if r > 180 && g > 130 && b < 110 { return 2 }   // yellow
        if r > 150 && g < 130 && b > 130 { return 6 }   // magenta
        if r < 110 && g > 130 && b > 130 { return 4 }   // cyan
        if r < 90 && g < 90 && b < 90 { return 250 }    // dark grey
        if r > 200 && g > 200 && b > 200 { return 7 }   // white
        return 8                                        // grey
    }

    /// Decimal places that keep full precision without printing noise.
    ///
    /// Shared with `XLSXWriter` on purpose: the number in the workbook is the
    /// number in the CSV, so a user comparing the two does not have to wonder
    /// which export is the accurate one.
    ///
    /// `separator` reaches the number itself, not the layout — the delimited
    /// formats pass theirs, everything else takes the default.
    static func decimal(_ v: Double, separator: DecimalSeparator = .dot) -> String {
        let text: String
        if v == 0 {
            text = "0"
        } else {
            let magnitude = abs(v)
            text = magnitude >= 1e6 || magnitude < 1e-4
                ? String(format: "%.6e", v)
                : String(format: "%.6f", v)
        }
        guard separator == .comma else { return text }
        // A replacement rather than a `%f` with a locale, and deliberately: a
        // locale-formatted number would make the exported bytes depend on the
        // machine that produced them, so the same project would leave two
        // different files from two colleagues' Macs and neither could be
        // compared with the other. `String(format:)` is documented as
        // unlocalised, so the dot is known to be there and to be the only one —
        // nothing else a number can contain (digits, `e`, `+`, `-`) is a dot.
        return text.replacingOccurrences(of: ".", with: separator.character)
    }

    private static func delimited(_ lines: [CurveLine],
                                  calibration: CalibrationMap?,
                                  format: ExportFormat,
                                  includeHeader: Bool,
                                  decimalSeparator: DecimalSeparator) throws -> String {
        let separator: String
        switch format {
        case .csv: separator = decimalSeparator.csvSeparator
        case .tsv: separator = "\t"
        default:   separator = " "
        }

        /// A number as this export wants it spelt. Local so the three layouts
        /// below cannot each pick their own answer.
        func number(_ v: Double) -> String { decimal(v, separator: decimalSeparator) }

        /// One curve's points as chart values, in display order.
        func rows(_ line: CurveLine) throws -> [DataPoint] {
            try line.orderedPoints.map { try value($0, calibration) }
        }

        // One curve: a plain two-column table.
        if lines.count <= 1 {
            var out = ""
            if includeHeader { out += "x\(separator)y\n" }
            for line in lines {
                for data in try rows(line) {
                    out += number(data.x) + separator + number(data.y) + "\n"
                }
            }
            return out
        }

        // Several curves. A spreadsheet and a person want opposite things from a
        // file of numbers, so they get different files rather than one
        // compromise:
        //
        //   · CSV and TSV are read by pandas, Excel and plotting scripts, and
        //     `# 名称` comment lines are **not part of the format** — pandas
        //     raises, and Excel quietly puts them in column A as a data row. Both
        //     are silently wrong, which is the worst kind. So the machine formats
        //     get a **wide table**: one header row, one x/y pair per curve.
        //   · TXT is read by eye, where a wide table with ragged rows is harder
        //     to follow than labelled blocks. It keeps them.
        //
        // The wide table pads short curves with empty cells rather than stopping,
        // because curves of a chart rarely have the same number of points and
        // truncating would silently drop data from whichever is longest.
        if format == .txt {
            var out = ""
            for (index, line) in lines.enumerated() {
                if includeHeader { out += "# \(line.name)\n" }
                for data in try rows(line) {
                    out += number(data.x) + separator + number(data.y) + "\n"
                }
                if index < lines.count - 1 { out += "\n" }
            }
            return out
        }

        let columns = try lines.map { try rows($0) }
        var out = ""
        if includeHeader {
            out += (1...lines.count).flatMap { ["x\($0)", "y\($0)"] }
                .joined(separator: separator) + "\n"
        }
        for row in 0..<(columns.map(\.count).max() ?? 0) {
            var cells: [String] = []
            for column in columns {
                if row < column.count {
                    cells.append(number(column[row].x))
                    cells.append(number(column[row].y))
                } else {
                    // Stayed empty on purpose: a hole in the middle of a row would
                    // shift every later column left and pair the wrong values.
                    cells.append("")
                    cells.append("")
                }
            }
            out += cells.joined(separator: separator) + "\n"
        }
        return out
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func xml(_ lines: [CurveLine],
                            calibration: CalibrationMap?) throws -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<graphdigger>\n"
        out += "  <calibration>\n"
        if let c = calibration {
            func axis(_ name: String, _ a: AxisCalibration) {
                out += "    <axis name=\"\(name)\" pixelMin=\"\(decimal(a.pixelMin))\""
                out += " valueMin=\"\(decimal(a.valueMin))\" pixelMax=\"\(decimal(a.pixelMax))\""
                out += " valueMax=\"\(decimal(a.valueMax))\" logarithmic=\"\(a.isLogarithmic)\"/>\n"
            }
            axis("x", c.x)
            axis("y", c.y)
        }
        out += "  </calibration>\n"
        for line in lines {
            out += "  <curve name=\"\(escaped(line.name))\">\n"
            for point in line.orderedPoints {
                let d = try value(point, calibration)
                out += "    <point x=\"\(decimal(d.x))\" y=\"\(decimal(d.y))\"/>\n"
            }
            out += "  </curve>\n"
        }
        out += "</graphdigger>\n"
        return out
    }

    /// Minimal DXF R12 (AC1009) with a POLYLINE entity per curve — the form
    /// every CAD package reads without complaint.
    private static func dxf(_ lines: [CurveLine],
                            calibration: CalibrationMap?) throws -> String {
        var out = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n0\nENDSEC\n"
        out += "0\nSECTION\n2\nENTITIES\n"
        for line in lines {
            out += "0\nPOLYLINE\n8\n\(escaped(line.name))\n66\n1\n70\n0\n"
            out += "62\n\(Self.aciIndex(for: line.color))\n"
            for point in line.orderedPoints {
                let d = try value(point, calibration)
                out += "0\nVERTEX\n8\n\(escaped(line.name))\n"
                out += "10\n\(decimal(d.x))\n20\n\(decimal(d.y))\n30\n0.0\n"
            }
            out += "0\nSEQEND\n"
        }
        out += "0\nENDSEC\n0\nEOF\n"
        return out
    }

    /// PostScript with a line per curve. Coordinates are emitted in data space
    /// after a translate to keep them positive.
    private static func eps(_ lines: [CurveLine],
                            calibration: CalibrationMap?) throws -> String {
        let all = try lines.flatMap { try $0.orderedPoints.map { try value($0, calibration) } }
        let minX = all.map(\.x).min() ?? 0, maxX = all.map(\.x).max() ?? 1
        let minY = all.map(\.y).min() ?? 0, maxY = all.map(\.y).max() ?? 1
        let width = max(maxX - minX, 1e-9), height = max(maxY - minY, 1e-9)
        let scale = 500.0 / max(width, height)

        var out = "%!PS-Adobe-3.0 EPSF-3.0\n"
        out += "%%BoundingBox: 0 0 560 560\n"
        out += "0.5 setlinewidth\n"
        for line in lines {
            out += "newpath\n"
            out += "\(decimal(Double(line.color.r) / 255)) "
            out += "\(decimal(Double(line.color.g) / 255)) "
            out += "\(decimal(Double(line.color.b) / 255)) setrgbcolor\n"
            for (i, point) in line.orderedPoints.enumerated() {
                let d = try value(point, calibration)
                let px = 30 + (d.x - minX) * scale
                let py = 30 + (d.y - minY) * scale
                out += i == 0
                    ? "\(decimal(px)) \(decimal(py)) moveto\n"
                    : "\(decimal(px)) \(decimal(py)) lineto\n"
            }
            out += "stroke\n"
        }
        out += "showpage\n%%EOF\n"
        return out
    }
}
