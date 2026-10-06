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
    public static func text(for lines: [CurveLine],
                            calibration: CalibrationMap?,
                            format: ExportFormat,
                            includeHeader: Bool = true) throws -> String {
        let populated = lines.filter { !$0.points.isEmpty }
        guard !populated.isEmpty else { throw ExportError.noPoints }

        switch format {
        case .csv, .tsv, .txt:
            return try delimited(populated, calibration: calibration,
                                 format: format, includeHeader: includeHeader)
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
                            includeHeader: Bool = true) throws -> Data {
        if format == .xlsx {
            return try XLSXWriter.data(for: lines, calibration: calibration)
        }
        return Data(try text(for: lines, calibration: calibration,
                             format: format, includeHeader: includeHeader).utf8)
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
    static func decimal(_ v: Double) -> String {
        if v == 0 { return "0" }
        let magnitude = abs(v)
        if magnitude >= 1e6 || magnitude < 1e-4 {
            return String(format: "%.6e", v)
        }
        return String(format: "%.6f", v)
    }

    private static func delimited(_ lines: [CurveLine],
                                  calibration: CalibrationMap?,
                                  format: ExportFormat,
                                  includeHeader: Bool) throws -> String {
        let separator: String
        switch format {
        case .csv: separator = ","
        case .tsv: separator = "\t"
        default:   separator = " "
        }

        var out = ""
        for (index, line) in lines.enumerated() {
            if includeHeader {
                if lines.count > 1 {
                    out += "# \(line.name)\n"
                }
                // A header row only makes sense for a single curve; with several
                // curves the columns repeat and the name comment carries it.
                if lines.count == 1 {
                    out += "x\(separator)y\n"
                }
            }
            for point in line.orderedPoints {
                let d = try value(point, calibration)
                out += decimal(d.x) + separator + decimal(d.y) + "\n"
            }
            if index < lines.count - 1 { out += "\n" }
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
