import XCTest
import GDCore

final class CalibrationTests: XCTestCase {

    func testLinearRoundTrip() throws {
        let axis = AxisCalibration(pixelMin: 100, valueMin: 0,
                                   pixelMax: 900, valueMax: 8)
        for v in [0.0, 1.3, 4.0, 7.9, 8.0] {
            let p = try axis.pixel(atValue: v)
            XCTAssertEqual(try axis.value(atPixel: p), v, accuracy: 1e-12)
        }
    }

    func testLogRoundTrip() throws {
        let axis = AxisCalibration(pixelMin: 50, valueMin: 0.1,
                                   pixelMax: 850, valueMax: 100,
                                   isLogarithmic: true)
        for v in [0.1, 1.0, 3.14, 100.0] {
            let p = try axis.pixel(atValue: v)
            XCTAssertEqual(try axis.value(atPixel: p), v, accuracy: 1e-10)
        }
    }

    func testLogMidpointIsGeometricMean() throws {
        let axis = AxisCalibration(pixelMin: 0, valueMin: 1,
                                   pixelMax: 100, valueMax: 1000,
                                   isLogarithmic: true)
        XCTAssertEqual(try axis.value(atPixel: 50), 1000.0.squareRoot(), accuracy: 1e-12)
    }

    func testLogRejectsNonPositiveValues() {
        let axis = AxisCalibration(pixelMin: 0, valueMin: -1,
                                   pixelMax: 100, valueMax: 10,
                                   isLogarithmic: true)
        XCTAssertThrowsError(try axis.value(atPixel: 50))
    }

    func testDegenerateAxisThrows() {
        let axis = AxisCalibration(pixelMin: 10, valueMin: 0,
                                   pixelMax: 10, valueMax: 5)
        XCTAssertThrowsError(try axis.value(atPixel: 10))
    }

    /// The Y axis runs bottom-to-top, so its pixel anchors are reversed in the
    /// usual case; the mapping must handle that without special-casing.
    func testReversedPixelAnchorsAreSupported() throws {
        let axis = AxisCalibration(pixelMin: 600, valueMin: 0,
                                   pixelMax: 40, valueMax: 50)
        XCTAssertEqual(try axis.value(atPixel: 600), 0, accuracy: 1e-12)
        XCTAssertEqual(try axis.value(atPixel: 40), 50, accuracy: 1e-12)
        XCTAssertEqual(try axis.value(atPixel: 320), 25, accuracy: 1e-9)
    }

    func testMapTwoDimensionalRoundTrip() throws {
        let map = CalibrationMap(
            x: AxisCalibration(pixelMin: 0, valueMin: -5, pixelMax: 800, valueMax: 5),
            y: AxisCalibration(pixelMin: 600, valueMin: 1, pixelMax: 40, valueMax: 50,
                               isLogarithmic: true))
        let p = PixelPoint(x: 123.5, y: 456.25)
        let d = try map.data(fromPixel: p)
        let back = try map.pixel(fromData: d)
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-8)
    }
}
