import XCTest
import GDCore

final class AxisTickTests: XCTestCase {

    func testNiceStepRoundsToOneTwoOrFive() {
        XCTAssertEqual(AxisCalibration.niceStep(0.9), 1, accuracy: 1e-12)
        XCTAssertEqual(AxisCalibration.niceStep(1.2), 1, accuracy: 1e-12)
        XCTAssertEqual(AxisCalibration.niceStep(1.7), 2, accuracy: 1e-12)
        XCTAssertEqual(AxisCalibration.niceStep(3.0), 2, accuracy: 1e-12)
        XCTAssertEqual(AxisCalibration.niceStep(4.0), 5, accuracy: 1e-12)
        XCTAssertEqual(AxisCalibration.niceStep(8.0), 10, accuracy: 1e-12)
        XCTAssertEqual(AxisCalibration.niceStep(120), 100, accuracy: 1e-9)
    }

    func testLinearTicksLandInsideThePixelRange() throws {
        let axis = AxisCalibration(pixelMin: 100, valueMin: 0, pixelMax: 900, valueMax: 8)
        let ticks = axis.ticks(overPixelRange: 100...900)
        XCTAssertFalse(ticks.isEmpty)
        for tick in ticks {
            XCTAssertGreaterThanOrEqual(tick.pixel, 100 - 1e-9)
            XCTAssertLessThanOrEqual(tick.pixel, 900 + 1e-9)
            // Each tick's pixel must round-trip to the value it advertises.
            let roundTripped = try axis.value(atPixel: tick.pixel)
            XCTAssertEqual(roundTripped, tick.value, accuracy: 1e-9)
        }
        XCTAssertTrue(ticks.contains { abs($0.value - 0) < 1e-9 })
        XCTAssertTrue(ticks.contains { abs($0.value - 8) < 1e-9 })
    }

    func testLinearTicksUseNiceRoundValues() throws {
        let axis = AxisCalibration(pixelMin: 0, valueMin: 0, pixelMax: 1000, valueMax: 100)
        let values = axis.ticks(overPixelRange: 0...1000).map(\.value)
        let first = try XCTUnwrap(values.first)
        XCTAssertEqual(first, 0, accuracy: 1e-9)
        // Step should be a round number, not 12.5 or similar.
        if values.count >= 2 {
            let step = values[1] - values[0]
            XCTAssertTrue([1, 2, 5, 10, 20, 25, 50].contains { abs($0 - step) < 1e-9 },
                          "step was \(step)")
        }
    }

    func testLogTicksIncludeDecades() {
        let axis = AxisCalibration(pixelMin: 0, valueMin: 1, pixelMax: 300, valueMax: 1000,
                                   isLogarithmic: true)
        let ticks = axis.ticks(overPixelRange: 0...300)
        let decades = ticks.filter { $0.isMajor }.map { $0.value }
        XCTAssertTrue(decades.contains { abs($0 - 1) < 1e-9 })
        XCTAssertTrue(decades.contains { abs($0 - 10) < 1e-9 })
        XCTAssertTrue(decades.contains { abs($0 - 100) < 1e-9 })
        XCTAssertTrue(decades.contains { abs($0 - 1000) < 1e-9 })
        // Log spacing is multiplicative: consecutive decades are equal in pixels.
        if let p1 = ticks.first(where: { abs($0.value - 1) < 1e-9 })?.pixel,
           let p10 = ticks.first(where: { abs($0.value - 10) < 1e-9 })?.pixel,
           let p100 = ticks.first(where: { abs($0.value - 100) < 1e-9 })?.pixel {
            XCTAssertEqual(p10 - p1, p100 - p10, accuracy: 1e-6)
        }
    }

    func testDegenerateAndInvalidInputsYieldNoTicks() {
        let flat = AxisCalibration(pixelMin: 50, valueMin: 0, pixelMax: 50, valueMax: 10)
        XCTAssertTrue(flat.ticks(overPixelRange: 0...100).isEmpty)

        let badLog = AxisCalibration(pixelMin: 0, valueMin: -1, pixelMax: 100, valueMax: 10,
                                     isLogarithmic: true)
        XCTAssertTrue(badLog.ticks(overPixelRange: 0...100).isEmpty)
    }

    func testReversedPixelAnchorsStillProduceOrderedTicks() {
        // The value axis is normally stored bottom-to-top.
        let axis = AxisCalibration(pixelMin: 600, valueMin: 0, pixelMax: 40, valueMax: 5)
        let ticks = axis.ticks(overPixelRange: 40...600)
        XCTAssertFalse(ticks.isEmpty)
        // Increasing value must mean decreasing pixel row.
        let sorted = ticks.sorted { $0.value < $1.value }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThan(b.pixel, a.pixel)
        }
    }
}

final class CalibrationAnchorTests: XCTestCase {

    /// The complaint that motivated this: with four unlabelled points there is
    /// nothing defining which end of an axis is the minimum. The mapping is
    /// defined by the clicked pixels, so a reversed pair must still map
    /// correctly rather than silently inverting the data.
    func testReversedClickOrderStillMapsCorrectly() throws {
        let calibration = CalibrationMap(
            // X minimum was clicked on the RIGHT, maximum on the LEFT.
            x: AxisCalibration(pixelMin: 800, valueMin: 0, pixelMax: 100, valueMax: 10),
            y: AxisCalibration(pixelMin: 600, valueMin: 0, pixelMax: 40, valueMax: 5))

        let atMin = try calibration.x.value(atPixel: 800)
        let atMax = try calibration.x.value(atPixel: 100)
        let atMid = try calibration.x.value(atPixel: 450)
        XCTAssertEqual(atMin, 0, accuracy: 1e-9)
        XCTAssertEqual(atMax, 10, accuracy: 1e-9)
        XCTAssertEqual(atMid, 5, accuracy: 1e-9)
        // And the vertical axis, bottom-to-top.
        let yAtBottom = try calibration.y.value(atPixel: 600)
        let yAtTop = try calibration.y.value(atPixel: 40)
        XCTAssertEqual(yAtBottom, 0, accuracy: 1e-9)
        XCTAssertEqual(yAtTop, 5, accuracy: 1e-9)
    }

    /// The four-click flow: each axis is defined by its own pair of anchors.
    func testApplyCalibrationFromFourAnchors() {
        var state = ProjectState()
        let anchors = CalibrationAnchors(xStart: PixelPoint(x: 100, y: 600),
                                         xEnd: PixelPoint(x: 900, y: 590),
                                         yStart: PixelPoint(x: 95, y: 600),
                                         yEnd: PixelPoint(x: 95, y: 40))

        let map = state.applyCalibration(anchors: anchors,
                                         xStartValue: 0, xEndValue: 10,
                                         yStartValue: 0, yEndValue: 5,
                                         xIsLogarithmic: false, yIsLogarithmic: false)

        // Only each axis' own component is taken: the X end's row and the Y
        // end's column are ignored, so a slightly off-axis click is harmless.
        XCTAssertEqual(map.x.pixelMin, 100)
        XCTAssertEqual(map.x.pixelMax, 900)
        XCTAssertEqual(map.y.pixelMin, 600)
        XCTAssertEqual(map.y.pixelMax, 40)

        XCTAssertEqual(state.calibrationAnchors, anchors)
        XCTAssertEqual(state.calibrationAnchors?.ordered.count, 4)
    }

    /// The chart the four-anchor scheme exists for: an X rule along the bottom
    /// and a Y rule up the left that do not meet. Both start at a different row
    /// and column, and each axis must still map from its own anchors alone.
    func testAxesNeedNotShareAStart() throws {
        var state = ProjectState()
        let anchors = CalibrationAnchors(xStart: PixelPoint(x: 86, y: 488),
                                         xEnd: PixelPoint(x: 700, y: 488),
                                         yStart: PixelPoint(x: 90, y: 560),
                                         yEnd: PixelPoint(x: 90, y: 100))
        let map = state.applyCalibration(anchors: anchors,
                                         xStartValue: 0, xEndValue: 1,
                                         yStartValue: 0, yEndValue: 10,
                                         xIsLogarithmic: false, yIsLogarithmic: false)

        XCTAssertEqual(try map.x.value(atPixel: 86), 0, accuracy: 1e-9)
        XCTAssertEqual(try map.x.value(atPixel: 700), 1, accuracy: 1e-9)
        XCTAssertEqual(try map.y.value(atPixel: 560), 0, accuracy: 1e-9)
        XCTAssertEqual(try map.y.value(atPixel: 100), 10, accuracy: 1e-9)
        // The X rule's row is irrelevant to the Y mapping and vice versa: the
        // Y start's row (560) is nowhere near the X rule's (488).
        XCTAssertNotEqual(map.x.pixelMin, 0)
        XCTAssertEqual(map.x.pixelMin, 86)
        XCTAssertEqual(map.y.pixelMin, 560)
    }

    /// Editing the numbers must leave the clicked markers exactly where they
    /// are — that is the whole difference between this and re-calibrating.
    func testEditingValuesKeepsAnchors() throws {
        var state = ProjectState()
        let anchors = CalibrationAnchors(xStart: PixelPoint(x: 100, y: 600),
                                         xEnd: PixelPoint(x: 900, y: 600),
                                         yStart: PixelPoint(x: 100, y: 600),
                                         yEnd: PixelPoint(x: 100, y: 40))
        _ = state.applyCalibration(anchors: anchors,
                                   xStartValue: 0, xEndValue: 10,
                                   yStartValue: 0, yEndValue: 5,
                                   xIsLogarithmic: false, yIsLogarithmic: false)

        state.installCalibration(CalibrationMap(anchors: anchors,
                                                xStartValue: 100, xEndValue: 200,
                                                yStartValue: 273, yEndValue: 373))
        XCTAssertEqual(state.calibrationAnchors, anchors, "改数值不应移动标记")
        let edited = try XCTUnwrap(state.calibration)
        XCTAssertEqual(try edited.x.value(atPixel: 100), 100, accuracy: 1e-9)
        XCTAssertEqual(try edited.x.value(atPixel: 900), 200, accuracy: 1e-9)
        XCTAssertEqual(try edited.y.value(atPixel: 600), 273, accuracy: 1e-9)
        XCTAssertEqual(try edited.y.value(atPixel: 40), 373, accuracy: 1e-9)
    }

    /// A map built without anchors still draws something sensible: the fallback
    /// collapses both axis starts onto the low corner.
    func testFallbackAnchorsComeFromTheMap() {
        let map = CalibrationMap(
            x: AxisCalibration(pixelMin: 100, valueMin: 0, pixelMax: 900, valueMax: 10),
            y: AxisCalibration(pixelMin: 600, valueMin: 0, pixelMax: 40, valueMax: 5))
        let anchors = CalibrationAnchors(fallbackFrom: map)
        XCTAssertEqual(anchors.xStart, PixelPoint(x: 100, y: 600))
        XCTAssertEqual(anchors.xEnd, PixelPoint(x: 900, y: 600))
        XCTAssertEqual(anchors.yStart, PixelPoint(x: 100, y: 600))
        XCTAssertEqual(anchors.yEnd, PixelPoint(x: 100, y: 40))
    }

    /// A non-zero origin is what a chart with an offset axis looks like, e.g.
    /// a temperature plot starting at 273.
    func testNonZeroOriginValues() throws {
        var state = ProjectState()
        let map = state.applyCalibration(anchors: CalibrationAnchors(
                                             xStart: PixelPoint(x: 50, y: 500),
                                             xEnd: PixelPoint(x: 850, y: 500),
                                             yStart: PixelPoint(x: 50, y: 500),
                                             yEnd: PixelPoint(x: 50, y: 100)),
                                         xStartValue: 100, xEndValue: 200,
                                         yStartValue: 273, yEndValue: 373,
                                         xIsLogarithmic: false, yIsLogarithmic: false)
        XCTAssertEqual(try map.x.value(atPixel: 50), 100, accuracy: 1e-9)
        XCTAssertEqual(try map.x.value(atPixel: 850), 200, accuracy: 1e-9)
        XCTAssertEqual(try map.y.value(atPixel: 500), 273, accuracy: 1e-9)
        XCTAssertEqual(try map.y.value(atPixel: 100), 373, accuracy: 1e-9)
    }

    /// Drawing an axis right-to-left must still map correctly, because
    /// direction comes from the clicked pixels rather than the typing order.
    func testAxisDrawnRightToLeft() throws {
        var state = ProjectState()
        let map = state.applyCalibration(anchors: CalibrationAnchors(
                                             xStart: PixelPoint(x: 900, y: 600),
                                             xEnd: PixelPoint(x: 100, y: 600),
                                             yStart: PixelPoint(x: 900, y: 600),
                                             yEnd: PixelPoint(x: 900, y: 40)),
                                         xStartValue: 0, xEndValue: 10,
                                         yStartValue: 0, yEndValue: 5,
                                         xIsLogarithmic: false, yIsLogarithmic: false)
        XCTAssertEqual(try map.x.value(atPixel: 900), 0, accuracy: 1e-9)
        XCTAssertEqual(try map.x.value(atPixel: 100), 10, accuracy: 1e-9)
        XCTAssertEqual(try map.x.value(atPixel: 500), 5, accuracy: 1e-9)
    }

    func testClearCalibrationKeepsExtractedPoints() {
        var state = ProjectState()
        state.applyCalibration(anchors: CalibrationAnchors(
                                   xStart: PixelPoint(x: 0, y: 10),
                                   xEnd: PixelPoint(x: 10, y: 10),
                                   yStart: PixelPoint(x: 0, y: 10),
                                   yEnd: PixelPoint(x: 0, y: 0)),
                               xStartValue: 0, xEndValue: 1,
                               yStartValue: 0, yEndValue: 1,
                               xIsLogarithmic: false, yIsLogarithmic: false)
        state.append(points: [PixelPoint(x: 1, y: 2), PixelPoint(x: 3, y: 4)],
                     usingDefaultColor: RGB8(r: 1, g: 1, b: 1))

        state.clearCalibration()
        XCTAssertNil(state.calibration)
        XCTAssertNil(state.calibrationAnchors)
        // Points are stored in pixel space, so they outlive the calibration.
        XCTAssertEqual(state.activeLine?.points.count, 2)
    }

    /// The click order the canvas collects and the canvas' prompts both read
    /// from; four names, in the order the four clicks arrive.
    func testAnchorOrderMatchesTheClickFlow() {
        let anchors = CalibrationAnchors(ordered: [
            PixelPoint(x: 1, y: 1), PixelPoint(x: 2, y: 2),
            PixelPoint(x: 3, y: 3), PixelPoint(x: 4, y: 4),
        ])
        XCTAssertEqual(anchors?.xStart, PixelPoint(x: 1, y: 1))
        XCTAssertEqual(anchors?.xEnd, PixelPoint(x: 2, y: 2))
        XCTAssertEqual(anchors?.yStart, PixelPoint(x: 3, y: 3))
        XCTAssertEqual(anchors?.yEnd, PixelPoint(x: 4, y: 4))
        XCTAssertNil(CalibrationAnchors(ordered: [PixelPoint(x: 1, y: 1)]))
        XCTAssertEqual(CalibrationAnchors.clickOrder.count, 4)
    }

    /// Dragging one axis' handle must not disturb the other axis.
    func testDraggingOneAxisLeavesTheOtherUntouched() {
        var map = CalibrationMap(
            x: AxisCalibration(pixelMin: 100, valueMin: 0, pixelMax: 900, valueMax: 10),
            y: AxisCalibration(pixelMin: 600, valueMin: 0, pixelMax: 40, valueMax: 5))
        let originalY = map.y

        map.x.pixelMin = 150
        XCTAssertEqual(map.y, originalY)
        let afterDrag = try? map.x.value(atPixel: 150)
        XCTAssertEqual(afterDrag ?? .nan, 0, accuracy: 1e-9)
    }
}
