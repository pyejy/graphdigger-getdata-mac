import XCTest
@testable import GDCore

/// The project container.
///
/// What these are about is the promise the feature makes: a file saved today
/// opens tomorrow, in someone else's copy, showing the same thing. Every check
/// below is a way that promise can be broken — a field silently left out of the
/// header, an image re-encoded instead of copied, a corrupt file accepted and
/// drawn as an empty project.
final class ProjectFileTests: XCTestCase {

    // MARK: - Fixtures

    /// A state with something in every field the file is supposed to carry.
    ///
    /// Deliberately not `ProjectState()`: a round trip through a default state
    /// would pass even if the header dropped half its keys, because the defaults
    /// would come back from the decoder rather than from the file.
    private func populatedState() -> ProjectState {
        var state = ProjectState()

        let anchors = CalibrationAnchors(
            xStart: PixelPoint(x: 120, y: 800),
            xEnd: PixelPoint(x: 1180, y: 800),
            yStart: PixelPoint(x: 120, y: 800),
            yEnd: PixelPoint(x: 120, y: 60))
        state.applyCalibration(anchors: anchors,
                               xStartValue: 0, xEndValue: 10,
                               yStartValue: 0, yEndValue: 25,
                               xIsLogarithmic: false, yIsLogarithmic: true)

        state.defaultBackgroundColor = RGB8(r: 254, g: 254, b: 254)
        state.defaultColorTolerance = 72
        state.gridSpacing = 11
        state.traceSpacing = 3

        let red = RGB8(r: 200, g: 30, b: 40)
        let blue = RGB8(r: 20, g: 60, b: 210)

        state.addLine(name: "温度", color: red)
        state.setLineColor(red, for: state.activeLineID!)
        state.setBackgroundColor(RGB8(r: 255, g: 255, b: 255), for: state.activeLineID!)
        state.setColorTolerance(45, for: state.activeLineID!)
        state.append(points: [PixelPoint(x: 130, y: 790),
                              PixelPoint(x: 200, y: 700),
                              PixelPoint(x: 260, y: 640),
                              PixelPoint(x: 330, y: 520)],
                     usingDefaultColor: red)
        let firstID = state.activeLineID!

        state.addLine(name: "压力", color: blue)
        state.setLineColor(blue, for: state.activeLineID!)
        state.append(points: [PixelPoint(x: 140, y: 600),
                              PixelPoint(x: 240, y: 500),
                              PixelPoint(x: 340, y: 460)],
                     usingDefaultColor: blue)
        let secondID = state.activeLineID!

        // A sweep, so `sweptOrder` and the `.swept` presentation mode both have
        // to survive the trip. Indices are what the format stores, and they only
        // mean anything against the same point array.
        state.recordSweep([2, 0, 3, 1], for: firstID)
        state.setOrder(.ascendingX, for: secondID)
        // Visibility and the selection have no mutating helper on `ProjectState`
        // — the canvas owns those two, as display concerns — so they are set
        // through the properties here. Both still have to be in the file.
        if let index = state.lines.firstIndex(where: { $0.id == secondID }) {
            state.lines[index].isVisible = false
        }
        state.activeLineID = secondID

        return state
    }

    /// Not a real PNG — the format never looks inside the image bytes, and a
    /// made-up payload that is trivially recognisable is a better fixture than a
    /// binary blob nobody can eyeball in a diff.
    private let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        + Array(UInt8(0)...UInt8(200)))

    private func document(state: ProjectState? = nil) -> ProjectDocument {
        ProjectDocument(
            header: ProjectHeader(
                appVersion: "9.9.9",
                savedAt: Date(timeIntervalSince1970: 1_700_000_000),
                image: ProjectImageInfo(fileName: "chart.png", pixelWidth: 1200, pixelHeight: 900),
                state: state ?? populatedState()),
            imageData: imageBytes)
    }

    // MARK: - Round trip

    func testEverythingSurvivesTheRoundTrip() throws {
        let original = document()
        let restored = try ProjectDocument(serialized: original.serialized())
        XCTAssertEqual(restored, original)
    }

    func testTheDigitisingSessionComesBackFieldByField() throws {
        // Compared field by field as well as whole, so a failure says *which*
        // part of the session was lost rather than only that the structs differ.
        let state = populatedState()
        let restored = try ProjectDocument(serialized: document(state: state).serialized()).header.state

        XCTAssertEqual(restored.calibration, state.calibration)
        XCTAssertEqual(restored.calibration?.y.isLogarithmic, true, "对数刻度要跟着走")
        XCTAssertEqual(restored.calibrationAnchors, state.calibrationAnchors,
                       "四个标定标记的像素位置要跟着走,否则重新打开后轴线画在别处")
        XCTAssertEqual(restored.lines.count, 2)
        XCTAssertEqual(restored.activeLineID, state.activeLineID)
        XCTAssertEqual(restored.defaultBackgroundColor, state.defaultBackgroundColor)
        XCTAssertEqual(restored.defaultColorTolerance, state.defaultColorTolerance)
        XCTAssertEqual(restored.gridSpacing, state.gridSpacing)
        XCTAssertEqual(restored.traceSpacing, state.traceSpacing)
        XCTAssertEqual(restored.totalPointCount, 7)
    }

    func testEveryCurveKeepsItsOwnSettingsAndPoints() throws {
        let state = populatedState()
        let restored = try ProjectDocument(serialized: document(state: state).serialized()).header.state

        for (before, after) in zip(state.lines, restored.lines) {
            XCTAssertEqual(before.id, after.id, "曲线 id 是面板选中的依据,不能换")
            XCTAssertEqual(before.name, after.name)
            XCTAssertEqual(before.color, after.color)
            XCTAssertEqual(before.points, after.points, "点位是像素坐标,必须逐点一致")
            XCTAssertEqual(before.isVisible, after.isVisible)
            XCTAssertEqual(before.lineColor, after.lineColor)
            XCTAssertEqual(before.backgroundColor, after.backgroundColor)
            XCTAssertEqual(before.colorTolerance, after.colorTolerance)
            XCTAssertEqual(before.order, after.order)
            XCTAssertEqual(before.sweptOrder, after.sweptOrder)
        }
    }

    func testTheImageIsCopiedNotReEncoded() throws {
        // The property the whole design rests on. Points are pixel coordinates
        // into this image; anything that changed a byte of it would leave the
        // curves sitting against a picture that no longer exists.
        let original = document()
        let restored = try ProjectDocument(serialized: original.serialized())
        XCTAssertEqual(restored.imageData, imageBytes)
        XCTAssertEqual(Array(restored.imageData), Array(imageBytes), "逐字节,不是逐像素")
    }

    func testTheHeaderIsHumanReadableJSON() throws {
        // The structured half is plain UTF-8 JSON between the prologue and the
        // image: that is what makes a broken file diagnosable instead of opaque,
        // and it is why the layout puts the two halves in that order.
        let data = try document().serialized()
        let headerLength = Int(data[12]) | Int(data[13]) << 8
            | Int(data[14]) << 16 | Int(data[15]) << 24
        let header = data.subdata(in: 16..<(16 + headerLength))

        XCTAssertEqual(String(data: data.prefix(8), encoding: .utf8), "GDIGPRJ\u{0}")
        XCTAssertNotNil(String(data: header, encoding: .utf8), "头部应当是 UTF-8")
        XCTAssertTrue(String(data: header, encoding: .utf8)?.contains("\"savedAt\"") == true)
    }

    func testTheImageIsTheLastThingInTheFile() throws {
        // Nothing follows it. A trailer would make the reader guess at its own
        // length, and the whole point of the layout is that it never has to.
        let data = try document().serialized()
        XCTAssertGreaterThan(data.count, imageBytes.count)
        XCTAssertEqual(Array(data.suffix(imageBytes.count)), Array(imageBytes))
    }

    func testASlicedFileDecodesTheSameAsAWholeOne() throws {
        // A `Data` taken as a slice of a bigger buffer keeps its parent's
        // indices. The reader must not care — callers hand over slices more often
        // than they mean to.
        let whole = try document().serialized()
        var padded = Data(repeating: 0xAB, count: 64)
        padded.append(whole)
        let sliced = padded.dropFirst(64)

        XCTAssertEqual(try ProjectDocument(serialized: sliced).header.image.fileName, "chart.png")
    }

    func testAnEmptySessionIsStillAValidProject() throws {
        // A project saved before anything was digitised — the image on its own —
        // is legitimate: it is what "save now, label the axes later" produces.
        var bare = ProjectState()
        bare.defaultBackgroundColor = RGB8(r: 255, g: 255, b: 255)
        let restored = try ProjectDocument(serialized: document(state: bare).serialized())
        XCTAssertTrue(restored.header.state.lines.isEmpty)
        XCTAssertNil(restored.header.state.calibration)
        XCTAssertEqual(restored.imageData, imageBytes)
    }

    func testTheInformationalFieldsAreOptional() throws {
        // `appVersion` and `savedAt` may be absent — a caller with no bundle, or
        // a file from a build that predates them. Decoding has to tolerate that,
        // which is why they are optional; this pins it.
        let document = ProjectDocument(
            header: ProjectHeader(image: ProjectImageInfo(pixelWidth: 10, pixelHeight: 10),
                                  state: ProjectState()),
            imageData: imageBytes)
        let restored = try ProjectDocument(serialized: document.serialized())
        XCTAssertNil(restored.header.appVersion)
        XCTAssertNil(restored.header.savedAt)
    }

    // MARK: - Rejecting what is not ours

    func testAPlainImageIsNotAProject() {
        XCTAssertThrowsError(try ProjectDocument(serialized: imageBytes)) { error in
            XCTAssertEqual(error as? ProjectFileError, .notAProjectFile)
        }
    }

    func testSomethingShorterThanThePrologueIsRejected() {
        XCTAssertThrowsError(try ProjectDocument(serialized: Data([0x47, 0x44, 0x49]))) { error in
            XCTAssertEqual(error as? ProjectFileError, .notAProjectFile)
        }
        XCTAssertThrowsError(try ProjectDocument(serialized: Data())) { error in
            XCTAssertEqual(error as? ProjectFileError, .notAProjectFile)
        }
    }

    func testAFileFromANewerFormatIsRefusedByVersion() {
        var data = (try? document().serialized()) ?? Data()
        data[8] = UInt8(ProjectFile.currentVersion + 7)
        data[9] = 0

        XCTAssertThrowsError(try ProjectDocument(serialized: data)) { error in
            XCTAssertEqual(error as? ProjectFileError,
                           .unsupportedVersion(ProjectFile.currentVersion + 7),
                           "要说清是版本问题,而不是笼统的\"文件损坏\"")
        }
    }

    func testATruncatedHeaderIsRejected() {
        var data = (try? document().serialized()) ?? Data()
        // Promise far more header than the file holds.
        data[12] = 0xFF
        data[13] = 0xFF
        data[14] = 0xFF
        data[15] = 0x0F

        XCTAssertThrowsError(try ProjectDocument(serialized: data)) { error in
            XCTAssertEqual(error as? ProjectFileError, .truncatedHeader)
        }
    }

    func testAHeaderThatIsNotJSONIsRejected() {
        var data = (try? document().serialized()) ?? Data()
        // The same length, different contents: this is what a file that was
        // overwritten in place, or assembled from the wrong pieces, looks like.
        let headerLength = Int(data[12]) | Int(data[13]) << 8
            | Int(data[14]) << 16 | Int(data[15]) << 24
        XCTAssertGreaterThan(headerLength, 4)
        for offset in 16..<(16 + headerLength) { data[offset] = 0x7A }   // "zzzz…"

        XCTAssertThrowsError(try ProjectDocument(serialized: data)) { error in
            XCTAssertEqual(error as? ProjectFileError, .malformedHeader)
        }
    }

    func testAProjectWithNoImageIsRejected() {
        // A valid header with nothing behind it. Accepting this would open a
        // window with curves on an image that does not exist.
        var data = (try? document().serialized()) ?? Data()
        let headerLength = Int(data[12]) | Int(data[13]) << 8
            | Int(data[14]) << 16 | Int(data[15]) << 24
        data.removeSubrange((16 + headerLength)..<data.count)

        XCTAssertThrowsError(try ProjectDocument(serialized: data)) { error in
            XCTAssertEqual(error as? ProjectFileError, .missingImage)
        }
    }

    func testEveryErrorCanSayWhatWentWrong() {
        // `presentError` puts `localizedDescription` in front of the user, so a
        // case with no description would surface as a blank dialog.
        let cases: [ProjectFileError] = [
            .notAProjectFile, .unsupportedVersion(9), .truncatedHeader,
            .malformedHeader, .missingImage,
        ]
        for error in cases {
            let text = error.localizedDescription
            XCTAssertFalse(text.isEmpty, "\(error) 没有可读的说明")
            XCTAssertFalse(text.contains("The operation"), "\(error) 落回了系统默认文案")
        }
    }

    // MARK: - The format's own constants

    func testThePrologueIsSizedAsTheFormatDocuments() {
        // The offsets 8 and 12 in the reader and the writer are only correct
        // while this adds up; the number is stated once, here, so changing the
        // magic's length cannot silently move the version field.
        XCTAssertEqual(ProjectFile.prologueLength, ProjectFile.magic.count + 8)
    }

    func testTheExtensionAndTypeMatchWhatTheBundleRegisters() {
        // These two strings also appear in `scripts/build_universal.sh`. A drift
        // between them is a save panel offering a file the Finder will not hand
        // back to this app on a double-click.
        XCTAssertEqual(ProjectFile.fileExtension, "gdproj")
        XCTAssertEqual(ProjectFile.typeIdentifier, "com.example.graphdigger.project")
    }
}
