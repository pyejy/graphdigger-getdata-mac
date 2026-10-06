import Foundation

/// SpreadsheetML (`.xlsx`) output — FR-9.3.
///
/// ## Why this is hand-written
///
/// An `.xlsx` is a ZIP of XML parts. Foundation has no ZIP API and no XML writer
/// worth using here, so the two pieces are written out directly: `ZIPArchive`
/// (stored entries only) and this file's string templates. The alternative was a
/// third-party dependency in a project that has none, or spawning `/usr/bin/zip`
/// and inheriting an error path no test can reach.
///
/// ## Why one sheet per curve
///
/// The CSV and TSV writers put every curve in one stream with `# name` comments,
/// because a text file has nowhere else to put the name. A workbook does: a sheet
/// is a named container. So each curve gets its own sheet, named after the curve,
/// with `x` and `y` columns and nothing else — which is what makes the result
/// openable and immediately plottable rather than a file the user has to take
/// apart first.
///
/// ## Why the original's worst export complaint does not apply here
///
/// The original exports an `.xls` that opens read-only. Nothing in this format
/// asks for protection, so nothing here does either — the workbook is ordinary
/// and editable, which was the whole point of not reusing the original's format.
public enum XLSXWriter {

    /// A workbook with one worksheet per curve that has points.
    ///
    /// - Throws: `ExportError.noPoints` when there is nothing to write, so the
    ///   caller reports the same sentence the other formats do rather than saving
    ///   an empty workbook that looks like a success.
    public static func data(for lines: [CurveLine],
                            calibration: CalibrationMap?,
                            modified: Date = Date()) throws -> Data {
        let populated = lines.filter { !$0.points.isEmpty }
        guard !populated.isEmpty else { throw ExportError.noPoints }

        // Every value goes through the calibration, so a project with no
        // coordinate system fails here rather than writing pixel counts that look
        // like data.
        var sheets: [(name: String, rows: [[String]])] = []
        for line in populated {
            guard let calibration else { throw ExportError.calibrationMissing }
            var rows: [[String]] = [["x", "y"]]
            for point in line.orderedPoints {
                let value = try calibration.data(fromPixel: point)
                rows.append([Exporter.decimal(value.x), Exporter.decimal(value.y)])
            }
            sheets.append((line.name, rows))
        }

        let names = uniqueSheetNames(sheets.map(\.name))
        var entries: [ZIPArchive.Entry] = [
            .init(name: "[Content_Types].xml", data: contentTypes(sheetCount: sheets.count)),
            .init(name: "_rels/.rels", data: packageRelationships),
            .init(name: "xl/workbook.xml", data: workbook(names)),
            .init(name: "xl/_rels/workbook.xml.rels", data: workbookRelationships(sheetCount: sheets.count)),
        ]
        for (index, sheet) in sheets.enumerated() {
            entries.append(.init(name: "xl/worksheets/sheet\(index + 1).xml",
                                 data: worksheet(sheet.rows)))
        }
        return ZIPArchive.data(entries: entries, modified: modified)
    }

    // MARK: - Part templates
    //
    // Spelled out as literals rather than assembled from fragments: each part is
    // short, and a reader checking the output against the specification sees the
    // specification rather than a join of strings.

    private static func contentTypes(sheetCount: Int) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        """
        for index in 1...sheetCount {
            xml += "\n<Override PartName=\"/xl/worksheets/sheet\(index).xml\""
                + " ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        return Data((xml + "\n</Types>\n").utf8)
    }

    private static let packageRelationships = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>

    """.utf8)

    private static func workbook(_ names: [String]) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>
        """
        for (index, name) in names.enumerated() {
            xml += "\n<sheet name=\"\(escaped(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }
        return Data((xml + "\n</sheets>\n</workbook>\n").utf8)
    }

    private static func workbookRelationships(sheetCount: Int) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """
        for index in 1...sheetCount {
            xml += "\n<Relationship Id=\"rId\(index)\""
                + " Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\""
                + " Target=\"worksheets/sheet\(index).xml\"/>"
        }
        return Data((xml + "\n</Relationships>\n").utf8)
    }

    /// One worksheet: `x` and `y` in row 1, then the values.
    ///
    /// Strings are written inline (`t="inlineStr"`) rather than through a shared
    /// string table. The table exists to avoid repeating a string many times, and
    /// the only repeated strings here are the two column headings — so it would be
    /// a second part, a second set of indices to keep in step, and a larger file.
    /// Not private: a test asserts on the XML itself, which is cheaper and more
    /// direct than reaching it back out of the archive it was just packed into.
    static func worksheet(_ rows: [[String]]) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>
        """
        for (rowIndex, row) in rows.enumerated() {
            let rowNumber = rowIndex + 1
            xml += "\n<row r=\"\(rowNumber)\">"
            for (columnIndex, value) in row.enumerated() {
                let reference = "\(columnName(columnIndex))\(rowNumber)"
                if rowIndex == 0 {
                    xml += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(escaped(value))</t></is></c>"
                } else {
                    // A bare number: no type attribute means "number" in this
                    // format, which is what makes the column sum and plot without
                    // the user converting text to values first.
                    xml += "<c r=\"\(reference)\"><v>\(escaped(value))</v></c>"
                }
            }
            xml += "</row>"
        }
        return Data((xml + "\n</sheetData>\n</worksheet>\n").utf8)
    }

    // MARK: - Names and escaping

    /// Spreadsheet column letters: 0 → `A`, 25 → `Z`, 26 → `AA`.
    static func columnName(_ index: Int) -> String {
        var remaining = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(UInt8(65 + remaining % 26))) + name
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return name
    }

    /// Excel's rules for a sheet name: at most 31 characters, none of `[]:*?/\`,
    /// not empty, and unique within the workbook.
    ///
    /// Applied because a curve can be named anything at all — the rename field
    /// takes spaces and punctuation — and a workbook that names a sheet illegally
    /// is one Excel offers to repair rather than one that opens. Uniqueness is
    /// part of it: two curves called the same thing is legal in this app and not
    /// in a workbook.
    static func uniqueSheetNames(_ proposed: [String]) -> [String] {
        var taken: Set<String> = []
        return proposed.map { raw in
            var name = String(raw.map { "[]:*?/\\".contains($0) ? "_" : $0 })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = "曲线" }
            if name.count > 31 { name = String(name.prefix(31)) }

            var candidate = name
            var suffix = 2
            while taken.contains(candidate) {
                let tag = " (\(suffix))"
                candidate = String(name.prefix(max(0, 31 - tag.count))) + tag
                suffix += 1
            }
            taken.insert(candidate)
            return candidate
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
