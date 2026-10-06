import XCTest
@testable import GDCore

/// More than one pixel↔value mapping on one image — FR-13.
///
/// A journal figure with `(a)(b)(c)` subplots has three, and nothing about a
/// curve's pixels says which one it belongs to. The failure this feature exists
/// to prevent is silent: converting a curve through the wrong mapping produces
/// numbers that look entirely plausible and are wrong by the ratio between two
/// panels' ranges. So the checks below are mostly about *which* mapping each
/// curve gets, not about the mapping itself.
final class CoordinateSystemTests: XCTestCase {

    // MARK: - Fixtures

    private let imageBytes = Data([0x89, 0x50, 0x4E, 0x47] + Array(UInt8(0)...UInt8(60)))

    /// Two panels that differ by a factor of a hundred, so a curve converted
    /// through the wrong one is off by two digits rather than by a rounding.
    private func panelA() -> CalibrationMap {
        CalibrationMap.linear(xMin: 0, yMin: 0, xMax: 10, yMax: 10,
                              pixelXMin: 100, pixelYMin: 700,
                              pixelXMax: 500, pixelYMax: 300)
    }

    private func panelB() -> CalibrationMap {
        CalibrationMap.linear(xMin: 0, yMin: 0, xMax: 1000, yMax: 1000,
                              pixelXMin: 600, pixelYMin: 700,
                              pixelXMax: 1000, pixelYMax: 300)
    }

    /// A project with two systems and one curve in each.
    ///
    /// `ProjectState()` already brings one system, so only the second is added —
    /// and the two curves sit at the *same fraction* along their own panel's axes,
    /// which is what makes a shared mapping detectable: it would give both the
    /// same numbers.
    private func twoPanelState() -> (state: ProjectState, aID: UUID, bID: UUID) {
        var state = ProjectState()
        let aID = state.addLine(name: "a", color: RGB8(r: 200, g: 0, b: 0))
        state.append(points: [PixelPoint(x: 300, y: 500)],
                     usingDefaultColor: RGB8(r: 0, g: 0, b: 0))
        state.installCalibration(panelA())

        state.addCoordinateSystem(name: "坐标系 2")
        let bID = state.addLine(name: "b", color: RGB8(r: 0, g: 0, b: 200))
        state.append(points: [PixelPoint(x: 800, y: 500)],
                     usingDefaultColor: RGB8(r: 0, g: 0, b: 0))
        state.installCalibration(panelB())
        return (state, aID, bID)
    }

    // MARK: - The model

    func testAProjectStartsWithOneSystemSoEveryCurveHasAnOwner() {
        var state = ProjectState()
        XCTAssertEqual(state.systems.count, 1)
        XCTAssertNotNil(state.activeSystem)
        // The whole invariant: a curve can always say which system it is in, so
        // no conversion ever has to guess.
        let id = state.addLine(color: RGB8(r: 0, g: 0, b: 0))
        XCTAssertEqual(state.lines.first { $0.id == id }?.calibrationID, state.activeSystem?.id)
    }

    func testANewCurveJoinsTheActiveSystemNotTheFirstOne() {
        // Otherwise the second panel's curves silently land in the first panel's
        // units — the exact mistake this feature is for.
        var state = ProjectState()
        state.addCoordinateSystem()
        let second = state.activeSystem!.id
        let id = state.addLine(color: RGB8(r: 0, g: 0, b: 0))
        XCTAssertEqual(state.lines.first { $0.id == id }?.calibrationID, second)
    }

    func testEachCurveConvertsWithItsOwnMapping() throws {
        let (state, _, _) = twoPanelState()
        let resolver: CalibrationResolver = { state.calibration(for: $0) }
        let a = try Exporter.text(for: [state.lines[0]], calibration: nil, format: .csv,
                                  includeHeader: false, resolvingWith: resolver)
        let b = try Exporter.text(for: [state.lines[1]], calibration: nil, format: .csv,
                                  includeHeader: false, resolvingWith: resolver)

        XCTAssertTrue(a.hasPrefix("5.000000"), "曲线 a 按 A 面板的 0–10 换算,得到 \(a)")
        XCTAssertTrue(b.hasPrefix("500.000000"), "曲线 b 按 B 面板的 0–1000 换算,得到 \(b)")
        // The silent failure, stated positively: had both been converted with one
        // mapping, the two would be the same string.
        XCTAssertNotEqual(a, b)
    }

    func testACurveWhoseSystemIsUncalibratedFailsRatherThanBorrowingANeighbour() {
        // The resolver is authoritative: handing a fallback mapping alongside it
        // must not rescue a curve that has none of its own. Borrowing panel B's
        // range for a panel-A curve is the silent failure, and it leaves no trace
        // — the pixels do not move, only their meaning does.
        var state = ProjectState()
        state.addCoordinateSystem()
        state.installCalibration(panelB())
        state.setActiveCoordinateSystem(id: state.systems[0].id)
        _ = state.addLine(name: "a", color: RGB8(r: 0, g: 0, b: 0))
        state.append(points: [PixelPoint(x: 300, y: 500)],
                     usingDefaultColor: RGB8(r: 0, g: 0, b: 0))

        let resolver: CalibrationResolver = { state.calibration(for: $0) }
        XCTAssertThrowsError(
            try Exporter.text(for: state.lines, calibration: panelA(), format: .csv,
                               resolvingWith: resolver)
        ) { error in
            XCTAssertEqual(error as? ExportError, .calibrationMissing)
        }
    }

    func testWithoutAResolverTheSharedMappingIsStillUsed() throws {
        // Every caller written before this feature passes one mapping for the
        // whole project, and for a single-system project that is correct.
        var state = ProjectState()
        _ = state.addLine(name: "a", color: RGB8(r: 0, g: 0, b: 0))
        state.append(points: [PixelPoint(x: 300, y: 500)],
                     usingDefaultColor: RGB8(r: 0, g: 0, b: 0))
        let text = try Exporter.text(for: state.lines, calibration: panelA(), format: .csv,
                                     includeHeader: false)
        XCTAssertTrue(text.hasPrefix("5.000000"), "应当仍用传进来的那套映射: \(text)")
    }

    func testTheWorkbookConvertsEachSheetInItsOwnSystem() throws {
        // One sheet per curve, so this is the format where a shared mapping is
        // least visible to whoever opens it — and therefore the one worth
        // pinning. Compared as bytes with a fixed timestamp, because a workbook
        // whose every sheet came from the same mapping is otherwise
        // indistinguishable from one that did the right thing.
        let (state, _, _) = twoPanelState()
        let resolver: CalibrationResolver = { state.calibration(for: $0) }
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        let own = try XLSXWriter.data(for: state.lines, calibration: nil,
                                      resolvingWith: resolver, modified: when)
        let allWithA = try XLSXWriter.data(for: state.lines, calibration: panelA(),
                                           modified: when)
        XCTAssertNotEqual(own, allWithA, "两张表不该是同一套量程")
        // And the shared-mapping call is exactly what every caller before this
        // feature got, so the fallback still has to mean that.
        let shared = panelA()
        XCTAssertEqual(allWithA,
                       try XLSXWriter.data(for: state.lines, calibration: panelA(),
                                           resolvingWith: { _ in shared }, modified: when))
    }

    func testOneSystemProducesTheSameXMLAsBeforeThisFeature() throws {
        // The `curves` qualifier is added only when there is more than one block,
        // so every file written before FR-13 stays byte-identical.
        var state = ProjectState()
        _ = state.addLine(name: "a", color: RGB8(r: 0, g: 0, b: 0))
        state.append(points: [PixelPoint(x: 300, y: 500)],
                     usingDefaultColor: RGB8(r: 0, g: 0, b: 0))
        let text = try Exporter.text(for: state.lines, calibration: panelA(), format: .xml,
                                     resolvingWith: { _ in CalibrationMap.linear(
                                        xMin: 0, yMin: 0, xMax: 10, yMax: 10,
                                        pixelXMin: 100, pixelYMin: 700,
                                        pixelXMax: 500, pixelYMax: 300) })
        XCTAssertTrue(text.contains("  <calibration>\n"), "单套时不加修饰: \(text)")
        XCTAssertFalse(text.contains("curves="))
    }

    func testTwoSystemsSayWhichCurvesEachBlockMeasured() throws {
        // A bare `<calibration>` with two of them would be an answer with no
        // question attached.
        let (state, _, _) = twoPanelState()
        let resolver: CalibrationResolver = { state.calibration(for: $0) }
        let text = try Exporter.text(for: state.lines, calibration: nil, format: .xml,
                                     resolvingWith: resolver)
        XCTAssertEqual(text.components(separatedBy: "<calibration ").count - 1, 2,
                       "两套坐标系要各有一个标定块: \(text)")
        XCTAssertTrue(text.contains("curves=\"a\""))
        XCTAssertTrue(text.contains("curves=\"b\""))
    }

    // MARK: - Editing

    func testDeletingIsRefusedWhileCurvesAreStillMeasuredInIt() {
        let (state, aID, _) = twoPanelState()
        var mutable = state
        XCTAssertFalse(mutable.removeCoordinateSystem(id: state.systems[0].id))
        XCTAssertEqual(mutable.systems.count, 2)
        XCTAssertEqual(mutable.curves(usingSystem: state.systems[0].id).count, 1)
        _ = aID

        // Once they are moved out, it goes.
        XCTAssertTrue(mutable.assign(curveID: aID, toSystem: state.systems[1].id))
        XCTAssertTrue(mutable.removeCoordinateSystem(id: state.systems[0].id))
        XCTAssertEqual(mutable.systems.count, 1)
    }

    func testDeletingTheLastOneIsRefused() {
        var state = ProjectState()
        XCTAssertFalse(state.removeCoordinateSystem(id: state.systems[0].id))
        XCTAssertEqual(state.systems.count, 1, "删掉最后一套会让曲线没有归属")
    }

    func testAssigningToAnUnknownSystemIsRefused() {
        var state = ProjectState()
        _ = state.addLine(color: RGB8(r: 0, g: 0, b: 0))
        let id = state.activeLineID!
        XCTAssertFalse(state.assign(curveID: id, toSystem: UUID()),
                       "归到一个不存在的坐标系会把曲线留在无人认领的状态")
        XCTAssertNotNil(state.lines[0].calibrationID)
    }

    func testAnActivePointerAtADeletedSystemFallsBackToTheFirst() {
        // A file can name an active system that is no longer there — the writer
        // that produced it did not refuse what this one refuses. Opening it must
        // still land on something.
        var state = ProjectState()
        state.addCoordinateSystem()
        state.addCoordinateSystem()
        let doomed = state.activeSystem!.id
        XCTAssertTrue(state.removeCoordinateSystem(id: doomed))
        XCTAssertNotNil(state.activeSystem)
        XCTAssertEqual(state.activeCoordinateSystemID, state.systems.first?.id)
    }

    func testLoadingANewImageReplacesEverySystem() {
        // They are all anchored to the picture that went away; keeping any of
        // them would label the new chart with the old one's axes.
        var state = ProjectState()
        state.installCalibration(panelA())
        state.addCoordinateSystem()
        state.installCalibration(panelB())
        state.resetCoordinateSystems()

        XCTAssertEqual(state.systems.count, 1)
        XCTAssertNil(state.systems[0].calibration)
        XCTAssertNil(state.systems[0].anchors)
    }

    /// Every system calibrated, or none of them — the status line's claim has to
    /// be true of the next export, which walks every curve.
    func testFullyCalibratedMeansAllOfThem() {
        let (state, _, _) = twoPanelState()
        XCTAssertTrue(state.isFullyCalibrated)

        // Clear the panel that is *not* being looked at and leave the active one
        // calibrated. The window would then read 标定完成, and the next export —
        // which walks every curve — would fail on the other panel. That is the
        // claim the status line must not make, so `isFullyCalibrated` has to be
        // about all of them and `calibration` about the one in hand.
        var partial = state
        partial.setActiveCoordinateSystem(id: partial.systems[0].id)
        partial.clearCalibration()
        partial.setActiveCoordinateSystem(id: partial.systems[1].id)

        XCTAssertFalse(partial.isFullyCalibrated)
        XCTAssertNotNil(partial.calibration, "活跃那套还标定着")
        XCTAssertNil(partial.calibration(for: partial.lines[0]), "但曲线 a 的那套没了")
        XCTAssertEqual(partial.calibration, panelB())
    }

    // MARK: - The file format

    /// Rewrites a v2 header into the shape a build before this feature wrote:
    /// one `calibration` for the whole project, and curves that never had to say
    /// whose it was.
    private func asFormatV1(_ document: ProjectDocument) throws -> Data {
        let v2 = try document.serialized()
        let headerLength = Int(v2[12]) | Int(v2[13]) << 8
            | Int(v2[14]) << 16 | Int(v2[15]) << 24
        var header = try JSONSerialization.jsonObject(
            with: v2.subdata(in: 16..<(16 + headerLength))) as! [String: Any]
        var state = header["state"] as! [String: Any]
        let systems = state["coordinateSystems"] as! [[String: Any]]
        let first = systems[0]
        state["calibration"] = first["calibration"]
        state["calibrationAnchors"] = first["anchors"]
        state.removeValue(forKey: "coordinateSystems")
        state.removeValue(forKey: "activeCoordinateSystemID")
        var lines = state["lines"] as! [[String: Any]]
        for index in lines.indices { lines[index].removeValue(forKey: "calibrationID") }
        state["lines"] = lines
        header["state"] = state

        let body = try JSONSerialization.data(withJSONObject: header)
        var out = Data(ProjectFile.magic)
        // Format v1, little-endian — the version an older build wrote.
        for shift in [0, 8, 16, 24] { out.append(UInt8((1 >> shift) & 0xFF)) }
        for shift in [0, 8, 16, 24] { out.append(UInt8((body.count >> shift) & 0xFF)) }
        out.append(body)
        out.append(document.imageData)
        return out
    }

    private func document(state: ProjectState) -> ProjectDocument {
        ProjectDocument(
            header: ProjectHeader(
                appVersion: "0.3.1", savedAt: Date(timeIntervalSince1970: 1_700_000_000),
                image: ProjectImageInfo(fileName: "chart.png", pixelWidth: 1200,
                                        pixelHeight: 900),
                state: state),
            imageData: imageBytes)
    }

    func testThisBuildWritesFormatTwo() throws {
        let data = try document(state: twoPanelState().state).serialized()
        XCTAssertEqual(Int(data[8]), ProjectFile.currentVersion)
        XCTAssertEqual(ProjectFile.currentVersion, 2)
    }

    func testAFormatV1FileStillOpensAsOneSystem() throws {
        let (state, _, _) = twoPanelState()
        // A single-system project is what a v1 file actually was; a v1 file with
        // two panels' worth of curves is not a shape the old app could produce.
        var single = ProjectState()
        _ = single.addLine(name: "a", color: RGB8(r: 200, g: 0, b: 0))
        single.append(points: [PixelPoint(x: 300, y: 500)],
                      usingDefaultColor: RGB8(r: 0, g: 0, b: 0))
        single.installCalibration(panelA())
        _ = state

        let restored = try ProjectDocument(serialized: asFormatV1(document(state: single)))
        let opened = restored.header.state
        XCTAssertEqual(opened.systems.count, 1, "v1 的一个 calibration 要变成一个坐标系")
        XCTAssertEqual(opened.calibration, panelA())
        XCTAssertEqual(opened.lines.count, 1)
        // Without this the curves would have no owner, and the first save from
        // here would write a project that is ambiguous about something that was
        // never ambiguous before.
        XCTAssertEqual(opened.lines[0].calibrationID, ProjectState.firstSystemID)
        XCTAssertEqual(opened.calibration, opened.calibration(for: opened.lines[0]))
    }

    func testAFormatV1FileIsWrittenBackAsFormatTwoWithoutTheOldKeys() throws {
        // The v1 names are read and never written: a file carrying both shapes
        // would have two answers to "what is this project's calibration", and a
        // reader would have to guess which is current.
        var single = ProjectState()
        _ = single.addLine(name: "a", color: RGB8(r: 200, g: 0, b: 0))
        single.append(points: [PixelPoint(x: 300, y: 500)],
                      usingDefaultColor: RGB8(r: 0, g: 0, b: 0))
        single.installCalibration(panelA())

        let reopened = try ProjectDocument(serialized: asFormatV1(document(state: single)))
        let rewritten = try reopened.serialized()
        XCTAssertEqual(Int(rewritten[8]), 2, "再存一次要升到 v2")

        let headerLength = Int(rewritten[12]) | Int(rewritten[13]) << 8
            | Int(rewritten[14]) << 16 | Int(rewritten[15]) << 24
        let json = try JSONSerialization.jsonObject(
            with: rewritten.subdata(in: 16..<(16 + headerLength))) as! [String: Any]
        let stateJSON = json["state"] as! [String: Any]
        XCTAssertNil(stateJSON["calibration"], "不能再写 v1 的 calibration 键")
        XCTAssertNil(stateJSON["calibrationAnchors"], "不能再写 v1 的 anchors 键")
        XCTAssertNotNil(stateJSON["coordinateSystems"])
    }

    func testSeveralSystemsSurviveTheRoundTrip() throws {
        let (state, aID, bID) = twoPanelState()
        let restored = try ProjectDocument(serialized: document(state: state).serialized())
        XCTAssertEqual(restored.header.state, state)
        XCTAssertEqual(restored.header.state.systems.count, 2)
        // The ids are what each curve's owner is recorded as; if they changed on
        // the way through, every curve would come back unowned.
        XCTAssertEqual(restored.header.state.calibration(forSystem:
            restored.header.state.systems[0].id), panelA())
        XCTAssertEqual(restored.header.state.lines.first { $0.id == aID }?.calibrationID,
                       restored.header.state.systems[0].id)
        XCTAssertEqual(restored.header.state.lines.first { $0.id == bID }?.calibrationID,
                       restored.header.state.systems[1].id)
    }

    func testTheOrdinalIsWhatTheMenuAndStatusBarShow() {
        let (state, _, _) = twoPanelState()
        XCTAssertEqual(state.ordinal(ofSystem: state.systems[0].id), 1)
        XCTAssertEqual(state.ordinal(ofSystem: state.systems[1].id), 2)
        XCTAssertNil(state.ordinal(ofSystem: UUID()))
    }
}
