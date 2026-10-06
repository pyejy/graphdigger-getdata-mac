import XCTest
@testable import GDCore

/// The ZIP container and the workbook built on it — FR-9.3.
///
/// The independent verification for this format is not in here: an `.xlsx` was
/// written out and opened with a real ZIP reader, which checked every entry's
/// CRC, read the sheets back, and confirmed the numbers matched the calibration.
/// These tests are what keeps that from regressing — they pin the checksum
/// against published values and the XML against the shapes a reader expects.
final class XLSXTests: XCTestCase {

    // MARK: - CRC-32
    //
    // Pinned to values that come from outside this project, because a checksum
    // test that only agrees with the writer next to it proves nothing: the two
    // would share any mistake. `0xCBF43926` for "123456789" is the standard
    // check value for this polynomial.

    func testCRC32MatchesTheStandardCheckValues() {
        XCTAssertEqual(ZIPArchive.crc32(Data()), 0x0000_0000)
        XCTAssertEqual(ZIPArchive.crc32(Data("a".utf8)), 0xE8B7BE43)
        XCTAssertEqual(ZIPArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZIPArchive.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)),
                       0x414F_A339)
    }

    func testCRCDiffersWhenASingleBitDoes() {
        // The property the check exists for: a corrupted entry must not pass.
        let original = Data("temperature,x\n1.0,2.0\n".utf8)
        var corrupted = original
        corrupted[3] ^= 0x01
        XCTAssertNotEqual(ZIPArchive.crc32(original), ZIPArchive.crc32(corrupted))
    }

    // MARK: - Archive structure

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    func testTheArchiveIsWalkableEndToEnd() {
        // The three signatures a reader looks for, in the order it meets them,
        // plus the counts it trusts before allocating anything.
        let entries = [ZIPArchive.Entry(name: "a.txt", data: Data("hello".utf8)),
                       ZIPArchive.Entry(name: "dir/b.txt", data: Data("world!!".utf8))]
        let archive = ZIPArchive.data(entries: entries,
                                      modified: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(uint32(archive, at: 0), 0x0403_4B50, "开头必须是本地文件头")

        // The end record is the last 22 bytes: no comment, so its position is
        // fixed, and a reader that trusts the file to be complete starts here.
        let eocd = archive.count - 22
        XCTAssertEqual(uint32(archive, at: eocd), 0x0605_4B50, "结尾必须是中央目录结束记录")
        XCTAssertEqual(uint16(archive, at: eocd + 10), 2, "条目数")
        XCTAssertEqual(uint16(archive, at: eocd + 20), 0, "没有注释")

        // Where the directory sits, and how far it reaches. The two together have
        // to land exactly on the end record — that is the arithmetic a reader
        // relies on to find any entry at all, and an off-by-one here is a file
        // that opens as empty.
        let directoryOffset = Int(uint32(archive, at: eocd + 16))
        let directorySize = Int(uint32(archive, at: eocd + 12))
        XCTAssertLessThan(directoryOffset, eocd, "中央目录应当在结束记录之前")
        XCTAssertEqual(directoryOffset + directorySize, eocd,
                       "中央目录要正好铺到结束记录之前")
        XCTAssertEqual(uint32(archive, at: directoryOffset), 0x0201_4B50,
                       "偏移处必须是中央目录条目")
    }

    func testEachEntryIsStoredWithItsOwnChecksum() {
        let payload = Data("temperature,x\n1.0,2.0\n".utf8)
        let archive = ZIPArchive.data(entries: [.init(name: "sheet.xml", data: payload)],
                                      modified: Date(timeIntervalSince1970: 0))
        // Local header: signature(4) version(2) flags(2) method(2) time(2) date(2)
        //               crc(4) compressed(4) uncompressed(4) ...
        XCTAssertEqual(uint16(archive, at: 8), 0, "方法应为 0(stored)")
        XCTAssertEqual(uint32(archive, at: 14), ZIPArchive.crc32(payload), "本地头的 CRC")
        XCTAssertEqual(uint32(archive, at: 18), UInt32(payload.count))
        XCTAssertEqual(uint32(archive, at: 22), UInt32(payload.count),
                       "未压缩大小要与压缩大小相等 —— 没有压缩")
        XCTAssertEqual(uint16(archive, at: 26), UInt16("sheet.xml".utf8.count))
    }

    func testAnEmptyArchiveIsStillAValidOne() {
        let archive = ZIPArchive.data(entries: [], modified: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(archive.count, 22)
        XCTAssertEqual(uint32(archive, at: 0), 0x0605_4B50)
        XCTAssertEqual(uint16(archive, at: 10), 0)
    }

    func testTheTimestampIsTheCallersSoTheOutputCanBeReproduced() {
        let early = ZIPArchive.data(entries: [.init(name: "a", data: Data())],
                                    modified: Date(timeIntervalSince1970: 0))
        let later = ZIPArchive.data(entries: [.init(name: "a", data: Data())],
                                    modified: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertNotEqual(early, later, "时间戳应当跟着传进来的日期走")

        // Two calls with the same date are byte-identical: what makes a test on
        // the whole archive possible at all.
        let again = ZIPArchive.data(entries: [.init(name: "a", data: Data())],
                                    modified: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(early, again)
    }

    // MARK: - Column letters

    func testColumnLettersRollOverLikeASpreadsheet() {
        XCTAssertEqual(XLSXWriter.columnName(0), "A")
        XCTAssertEqual(XLSXWriter.columnName(1), "B")
        XCTAssertEqual(XLSXWriter.columnName(25), "Z")
        XCTAssertEqual(XLSXWriter.columnName(26), "AA")
        XCTAssertEqual(XLSXWriter.columnName(27), "AB")
        XCTAssertEqual(XLSXWriter.columnName(51), "AZ")
        XCTAssertEqual(XLSXWriter.columnName(52), "BA")
        XCTAssertEqual(XLSXWriter.columnName(701), "ZZ")
        XCTAssertEqual(XLSXWriter.columnName(702), "AAA")
    }

    // MARK: - Sheet names

    func testSheetNamesAreMadeLegalForAWorkbook() {
        // A curve can be renamed to anything at all, so every rule the format
        // imposes has to be applied rather than assumed.
        let names = XLSXWriter.uniqueSheetNames([
            "压力/MPa [支]",              // illegal characters
            String(repeating: "很长", count: 20),  // over 31 characters
            "   ",                        // empty once trimmed
            "曲线 1",
            "曲线 1",                     // a duplicate, which the app allows
        ])

        XCTAssertEqual(names.count, 5)
        XCTAssertFalse(names[0].contains("/"), "斜杠必须换掉:\(names[0])")
        XCTAssertFalse(names[0].contains("["))
        XCTAssertFalse(names[0].contains("]"))
        XCTAssertLessThanOrEqual(names[1].count, 31, "长度上限 31:\(names[1].count)")
        XCTAssertFalse(names[2].trimmingCharacters(in: .whitespaces).isEmpty, "空名字要有个兜底")
        XCTAssertNotEqual(names[3], names[4], "重名必须被区分开")
        XCTAssertEqual(Set(names).count, 5, "表名要唯一")
        for name in names {
            XCTAssertFalse(name.isEmpty)
            XCTAssertLessThanOrEqual(name.count, 31)
        }
    }

    func testASheetNameKeepsItsMeaningWhenItIsMadeLegal() {
        // Sanitising must not throw the name away: 压力/MPa should still read as
        // 压力_MPa, not become 曲线.
        let names = XLSXWriter.uniqueSheetNames(["压力/MPa"])
        XCTAssertEqual(names[0], "压力_MPa")
    }

    // MARK: - Worksheet XML

    func testTheHeaderRowIsAStringAndTheDataRowsAreNumbers() throws {
        // The distinction the format cares about most: a number written as text
        // looks identical in a cell and refuses to plot, sum or sort.
        let xml = String(decoding: XLSXWriter.worksheet([["x", "y"], ["1.500000", "0"]]), as: UTF8.self)

        XCTAssertTrue(xml.contains("t=\"inlineStr\""), "表头应当内联字符串")
        XCTAssertTrue(xml.contains("<is><t>x</t></is>"))
        XCTAssertTrue(xml.contains("<row r=\"1\">"))
        XCTAssertTrue(xml.contains("<c r=\"A2\"><v>1.500000</v></c>"), "数据单元格要**没有** t 属性(即数字)")
        XCTAssertTrue(xml.contains("<c r=\"B2\"><v>0</v></c>"))
        XCTAssertFalse(xml.contains("t=\"inlineStr\"><is><t>1.5"), "数值不能被写成字符串")
    }

    func testCellReferencesFollowTheirPosition() throws {
        let rows = [["x", "y", "注释"], ["1", "2", "3"]]
        let xml = String(decoding: XLSXWriter.worksheet(rows), as: UTF8.self)
        XCTAssertTrue(xml.contains("<c r=\"C1\""), "第三列是 C")
        XCTAssertTrue(xml.contains("<c r=\"C2\""))
    }

    func testTheWorksheetIsWellFormedXML() throws {
        let xml = XLSXWriter.worksheet([["x", "y"], ["1.000000", "2.000000"]])
        // Parsed rather than pattern-matched: a stray bracket is the likeliest
        // way to produce a file Excel offers to repair, and only a parser sees it.
        XCTAssertNoThrow(try XMLDocument(data: xml))
    }

    // MARK: - The whole workbook

    func testTheWorkbookCarriesOneSheetPerCurveAndFailsWhenThereIsNothing() throws {
        let calibration = CalibrationMap.linear(xMin: 0, yMin: 0, xMax: 10, yMax: 5,
                                                pixelXMin: 0, pixelYMin: 100,
                                                pixelXMax: 100, pixelYMax: 0)
        let a = CurveLine(name: "A", color: RGB8(r: 1, g: 2, b: 3),
                          points: [PixelPoint(x: 10, y: 50), PixelPoint(x: 20, y: 60)])
        let b = CurveLine(name: "B", color: RGB8(r: 4, g: 5, b: 6),
                          points: [PixelPoint(x: 30, y: 70)])
        let data = try XLSXWriter.data(for: [a, b], calibration: calibration,
                                       modified: Date(timeIntervalSince1970: 0))

        // The part names appear verbatim in both the local header and the
        // directory, so a search of the bytes is a fair way to ask "is it in
        // there" without writing a reader.
        for part in ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml",
                     "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml",
                     "xl/worksheets/sheet2.xml"] {
            XCTAssertTrue(data.range(of: Data(part.utf8)) != nil, "缺少部件 \(part)")
        }
        XCTAssertTrue(data.range(of: Data("xl/worksheets/sheet3.xml".utf8)) == nil,
                      "两条曲线只该有两张表")
        XCTAssertTrue(data.range(of: Data("A".utf8)) != nil)

        // An empty project is an error rather than an empty workbook: a file that
        // opens to nothing looks like a success and is not one.
        XCTAssertThrowsError(try XLSXWriter.data(for: [], calibration: calibration)) { error in
            XCTAssertEqual(error as? ExportError, .noPoints)
        }
    }

    func testAWorkbookNeedsACalibrationLikeEveryOtherExport() {
        let line = CurveLine(name: "A", color: RGB8(r: 1, g: 2, b: 3),
                             points: [PixelPoint(x: 10, y: 50)])
        XCTAssertThrowsError(try XLSXWriter.data(for: [line], calibration: nil)) { error in
            XCTAssertEqual(error as? ExportError, .calibrationMissing)
        }
    }

    // MARK: - The shared entry point

    func testTheBinaryFormatIsRefusedByTheTextWriter() {
        // Not reachable through the app, which routes by `isText` — but a `text`
        // call that quietly returned something for `.xlsx` would hand the caller
        // a string that is not the file it asked for.
        let line = CurveLine(name: "A", color: RGB8(r: 1, g: 2, b: 3),
                             points: [PixelPoint(x: 10, y: 50)])
        let calibration = CalibrationMap.linear(xMin: 0, yMin: 0, xMax: 1, yMax: 1,
                                                pixelXMin: 0, pixelYMin: 0,
                                                pixelXMax: 1, pixelYMax: 1)
        XCTAssertThrowsError(try Exporter.text(for: [line], calibration: calibration,
                                               format: .xlsx)) { error in
            XCTAssertEqual(error as? ExportError, .notATextFormat)
        }
        XCTAssertFalse(ExportFormat.xlsx.isText, "工作簿不是文本格式")
        XCTAssertTrue(ExportFormat.csv.isText)
    }

    func testEveryFormatSaysWhetherItIsText() {
        // The flag is what routes the save panel, so a new format that forgot to
        // answer would be routed as text and written as mojibake.
        for format in ExportFormat.allCases {
            XCTAssertEqual(format.isText, format != .xlsx, "\(format) 的 isText 不对")
            XCTAssertFalse(format.fileExtension.isEmpty)
            XCTAssertFalse(format.displayName.isEmpty)
        }
    }
}
