import Foundation

/// One axis' pixel-to-value mapping, defined by two anchors in pixel space with
/// their known values. Linear or base-10 logarithmic.
///
/// Anchors may run in either direction: `pixelMin > pixelMax` is legal and is
/// in fact the norm for the Y axis, where pixel rows grow downward while values
/// grow upward.
public struct AxisCalibration: Equatable, Codable, Sendable {
    public var pixelMin: Double
    public var valueMin: Double
    public var pixelMax: Double
    public var valueMax: Double
    public var isLogarithmic: Bool

    public init(pixelMin: Double, valueMin: Double,
                pixelMax: Double, valueMax: Double,
                isLogarithmic: Bool = false) {
        self.pixelMin = pixelMin
        self.valueMin = valueMin
        self.pixelMax = pixelMax
        self.valueMax = valueMax
        self.isLogarithmic = isLogarithmic
    }

    /// Value shown by the axis at a pixel position.
    public func value(atPixel p: Double) throws -> Double {
        guard pixelMax != pixelMin else { throw GeometryError.degenerateAxis }
        if isLogarithmic, Swift.min(valueMin, valueMax) <= 0 {
            throw GeometryError.logScaleRequiresPositiveValues
        }
        let t = (p - pixelMin) / (pixelMax - pixelMin)
        if isLogarithmic {
            let l0 = log10(valueMin), l1 = log10(valueMax)
            return pow(10.0, l0 + t * (l1 - l0))
        }
        return valueMin + t * (valueMax - valueMin)
    }

    /// Pixel position showing a given value (inverse of `value(atPixel:)`).
    public func pixel(atValue v: Double) throws -> Double {
        guard pixelMax != pixelMin else { throw GeometryError.degenerateAxis }
        let t: Double
        if isLogarithmic {
            guard Swift.min(valueMin, valueMax) > 0 else {
                throw GeometryError.logScaleRequiresPositiveValues
            }
            guard v > 0 else { throw GeometryError.logScaleRequiresPositiveValues }
            let l0 = log10(valueMin), l1 = log10(valueMax)
            t = (log10(v) - l0) / (l1 - l0)
        } else {
            guard valueMax != valueMin else { throw GeometryError.degenerateAxis }
            t = (v - valueMin) / (valueMax - valueMin)
        }
        return pixelMin + t * (pixelMax - pixelMin)
    }
}

/// The four pixels the user clicked to define the coordinate system: the start
/// and end of each axis, in image space.
///
/// Four, not three, because the two axes need not meet. The three-point scheme
/// this replaces took a single "origin" corner and fed it to both axes' minima,
/// which silently mis-calibrates every chart drawn as two separate rules — an
/// X axis along the bottom, a Y axis up the left, neither reaching the other.
/// Those are common, and the four-point scheme costs the user one extra click.
///
/// Named fields rather than an array: the previous `[PixelPoint]?` had callers
/// indexing it positionally, and every one of those is a place a reordering
/// would have gone unnoticed.
public struct CalibrationAnchors: Equatable, Codable, Sendable {
    public var xStart: PixelPoint
    public var xEnd: PixelPoint
    public var yStart: PixelPoint
    public var yEnd: PixelPoint

    public init(xStart: PixelPoint, xEnd: PixelPoint, yStart: PixelPoint, yEnd: PixelPoint) {
        self.xStart = xStart
        self.xEnd = xEnd
        self.yStart = yStart
        self.yEnd = yEnd
    }

    /// The click order the calibration flow asks for: X start, X end, Y start,
    /// Y end. This is what the canvas collects and what the preview draws, so
    /// keeping the order in one place is what stops the two from disagreeing.
    public static let clickOrder = ["X 起始", "X 末端", "Y 起始", "Y 末端"]

    public init?(ordered points: [PixelPoint]) {
        guard points.count == 4 else { return nil }
        self.init(xStart: points[0], xEnd: points[1], yStart: points[2], yEnd: points[3])
    }

    /// The four anchors in click order.
    public var ordered: [PixelPoint] { [xStart, xEnd, yStart, yEnd] }

    /// A degenerate set for a calibration whose anchors were not kept — a map
    /// built before this type existed, or one restored without them. Both axis
    /// starts collapse onto the axes' own low corner, which is exactly the
    /// three-point assumption, so the rules still draw somewhere sensible
    /// instead of vanishing.
    public init(fallbackFrom map: CalibrationMap) {
        let corner = PixelPoint(x: map.x.pixelMin, y: map.y.pixelMin)
        self.init(xStart: corner,
                  xEnd: PixelPoint(x: map.x.pixelMax, y: map.y.pixelMin),
                  yStart: corner,
                  yEnd: PixelPoint(x: map.x.pixelMin, y: map.y.pixelMax))
    }
}

/// The full 2-D mapping for a chart: one calibration per axis.
public struct CalibrationMap: Equatable, Codable, Sendable {
    public var x: AxisCalibration
    public var y: AxisCalibration

    public init(x: AxisCalibration, y: AxisCalibration) {
        self.x = x
        self.y = y
    }

    /// Builds the mapping from four clicked anchors.
    ///
    /// Each axis reads only its own component from its own pair — X takes the
    /// columns, Y the rows — so a click that lands slightly off the rule is
    /// harmless, and direction follows whichever way the user drew the axis.
    /// Taking the two axes from separate anchor pairs is the whole point: the
    /// X axis' start row and the Y axis' start column are independent.
    public init(anchors: CalibrationAnchors,
                xStartValue: Double, xEndValue: Double,
                yStartValue: Double, yEndValue: Double,
                xIsLogarithmic: Bool = false, yIsLogarithmic: Bool = false) {
        self.init(
            x: AxisCalibration(pixelMin: anchors.xStart.x, valueMin: xStartValue,
                               pixelMax: anchors.xEnd.x, valueMax: xEndValue,
                               isLogarithmic: xIsLogarithmic),
            y: AxisCalibration(pixelMin: anchors.yStart.y, valueMin: yStartValue,
                               pixelMax: anchors.yEnd.y, valueMax: yEndValue,
                               isLogarithmic: yIsLogarithmic))
    }

    public func data(fromPixel p: PixelPoint) throws -> DataPoint {
        DataPoint(x: try x.value(atPixel: p.x), y: try y.value(atPixel: p.y))
    }

    public func pixel(fromData d: DataPoint) throws -> PixelPoint {
        PixelPoint(x: try x.pixel(atValue: d.x), y: try y.pixel(atValue: d.y))
    }

    /// Convenience for the common case of a linear axis pair.
    public static func linear(xMin: Double, yMin: Double, xMax: Double, yMax: Double,
                              pixelXMin: Double, pixelYMin: Double,
                              pixelXMax: Double, pixelYMax: Double) -> CalibrationMap {
        CalibrationMap(
            x: AxisCalibration(pixelMin: pixelXMin, valueMin: xMin,
                               pixelMax: pixelXMax, valueMax: xMax),
            y: AxisCalibration(pixelMin: pixelYMin, valueMin: yMin,
                               pixelMax: pixelYMax, valueMax: yMax))
    }
}
