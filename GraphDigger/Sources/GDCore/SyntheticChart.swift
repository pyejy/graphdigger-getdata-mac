import Foundation

/// Renders charts with analytically known curves.
///
/// Two uses in this project: the test suite compares extracted points against
/// exact ground truth (the corpus strategy the requirements doc asked for — no
/// sample images to ship, and the truth is exact), and the app can emit a
/// sample PNG so a first-time user has something to open.
public enum SyntheticChart {

    /// A rendered chart plus the geometry needed to calibrate it.
    public struct Chart: Sendable {
        public var buffer: BitmapBuffer
        /// Dense ground-truth polyline in pixel space.
        public var curvePixels: [PixelPoint]
        public var lineColor: RGB8
        public var backgroundColor: RGB8
        public var axisX0: Int
        public var axisX1: Int
        /// Pixel row of the value axis' minimum (bottom of the plot).
        public var axisY0: Int
        /// Pixel row of the value axis' maximum (top of the plot).
        public var axisY1: Int
        public var xMinValue: Double
        public var xMaxValue: Double
        public var yMinValue: Double
        public var yMaxValue: Double
        public var isLogY: Bool

        /// Calibration implied by the frame the generator drew — what a user
        /// would enter by clicking the four corners.
        public var calibration: CalibrationMap {
            CalibrationMap(
                x: AxisCalibration(pixelMin: Double(axisX0), valueMin: xMinValue,
                                   pixelMax: Double(axisX1), valueMax: xMaxValue),
                y: AxisCalibration(pixelMin: Double(axisY0), valueMin: yMinValue,
                                   pixelMax: Double(axisY1), valueMax: yMaxValue,
                                   isLogarithmic: isLogY))
        }

        /// The four reference pixels in the order the calibration sheet expects:
        /// X min, X max, Y min, Y max.
        public var calibrationPixels: [PixelPoint] {
            [PixelPoint(x: Double(axisX0), y: Double(axisY0)),
             PixelPoint(x: Double(axisX1), y: Double(axisY0)),
             PixelPoint(x: Double(axisX0), y: Double(axisY0)),
             PixelPoint(x: Double(axisX0), y: Double(axisY1))]
        }
    }

    public static let background = RGB8(r: 250, g: 250, b: 250)
    public static let ink = RGB8(r: 30, g: 30, b: 30)
    public static let curveColor = RGB8(r: 210, g: 40, b: 40)

    /// Colours of the charts produced by `renderMulti`. Deliberately far apart in
    /// RGB so a tolerance that captures one curve cannot capture another — which
    /// is the property the multi-curve extraction path depends on.
    public static let multiCurveColors: [RGB8] = [
        RGB8(r: 210, g: 40, b: 40),     // red
        RGB8(r: 30, g: 90, b: 200),     // blue
        RGB8(r: 30, g: 150, b: 60),     // green
    ]

    /// One curve of a multi-curve chart, with its own ground truth.
    public struct Series: Sendable {
        public var color: RGB8
        /// Dense ground-truth polyline in pixel space, left to right.
        public var pixels: [PixelPoint]
    }

    /// A chart carrying several independently coloured curves, which is what a
    /// real journal figure looks like and therefore what the multi-curve support
    /// has to be tested against.
    public struct MultiChart: Sendable {
        public var buffer: BitmapBuffer
        public var series: [Series]
        public var backgroundColor: RGB8
        public var axisX0: Int
        public var axisX1: Int
        public var axisY0: Int
        public var axisY1: Int
        public var xMinValue: Double
        public var xMaxValue: Double
        public var yMinValue: Double
        public var yMaxValue: Double
        public var isLogY: Bool

        public var calibration: CalibrationMap {
            CalibrationMap(
                x: AxisCalibration(pixelMin: Double(axisX0), valueMin: xMinValue,
                                   pixelMax: Double(axisX1), valueMax: xMaxValue),
                y: AxisCalibration(pixelMin: Double(axisY0), valueMin: yMinValue,
                                   pixelMax: Double(axisY1), valueMax: yMaxValue,
                                   isLogarithmic: isLogY))
        }

        public var lineColors: [RGB8] { series.map(\.color) }
    }

    /// Draws several curves on one set of axes.
    ///
    /// Every curve is sampled at the same x values, so the ground truth for a
    /// given column is shared and each curve can be checked against its own
    /// function independently of the others.
    ///
    /// The default functions keep each curve inside its own band of the value
    /// axis — 0.3…1.5, 2.0…3.2, 3.7…4.9 — so they never overlap. That is not for
    /// looks: where two curves cross, one repaints the other's pixels, and a
    /// test asserting "each curve's mask contains its own curve and no other"
    /// cannot be exact on a crossing. Curves that stay apart make the assertion
    /// exact, which is what catches a mask that leaks.
    public static func renderMulti(size: (width: Int, height: Int) = (900, 640),
                                   functions: [(Double) -> Double]? = nil,
                                   colors: [RGB8]? = nil,
                                   isLogY: Bool = false,
                                   lineWidth: Int = 3) -> MultiChart {
        let w = size.width, h = size.height
        let functions = functions ?? [
            { 0.9 + 0.6 * sin(0.5 * $0 + 0.3) },
            { 2.6 + 0.6 * sin(0.5 * $0 + 2.1) },
            { 4.3 + 0.6 * sin(0.5 * $0 + 4.2) },
        ]
        let colors = colors ?? Array(multiCurveColors.prefix(functions.count))
        precondition(colors.count >= functions.count, "one colour per curve")

        var pixels = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            pixels[i * 3] = background.r
            pixels[i * 3 + 1] = background.g
            pixels[i * 3 + 2] = background.b
        }

        let axX0 = 80, axX1 = w - 40
        let axY0 = h - 60, axY1 = 40
        let xMinV = 0.0, xMaxV = 10.0
        let yMinV = 0.0, yMaxV = 5.0

        @inline(__always)
        func toPixel(_ xv: Double, _ yv: Double) -> (Double, Double) {
            let tx = (xv - xMinV) / (xMaxV - xMinV)
            let ty = (yv - yMinV) / (yMaxV - yMinV)
            return (Double(axX0) + tx * Double(axX1 - axX0),
                    Double(axY0) + ty * Double(axY1 - axY0))
        }

        @inline(__always)
        func setPixel(_ x: Int, _ y: Int, _ c: RGB8) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            let i = (y * w + x) * 3
            pixels[i] = c.r; pixels[i + 1] = c.g; pixels[i + 2] = c.b
        }

        for x in axX0...axX1 { setPixel(x, axY0, ink) }
        for y in axY1...axY0 { setPixel(axX0, y, ink) }

        let samples = 2000
        var series: [Series] = []
        for (index, function) in functions.enumerated() {
            var curvePixels: [PixelPoint] = []
            curvePixels.reserveCapacity(samples + 1)
            for i in 0...samples {
                let xv = xMinV + (xMaxV - xMinV) * Double(i) / Double(samples)
                let (px, py) = toPixel(xv, function(xv))
                curvePixels.append(PixelPoint(x: px, y: py))
            }
            stroke(&pixels, width: w, height: h,
                   points: curvePixels, color: colors[index], lineWidth: lineWidth)
            series.append(Series(color: colors[index], pixels: curvePixels))
        }

        return MultiChart(buffer: BitmapBuffer(width: w, height: h, pixels: pixels),
                          series: series,
                          backgroundColor: background,
                          axisX0: axX0, axisX1: axX1,
                          axisY0: axY0, axisY1: axY1,
                          xMinValue: xMinV, xMaxValue: xMaxV,
                          yMinValue: yMinV, yMaxValue: yMaxV,
                          isLogY: isLogY)
    }

    /// - Parameters:
    ///   - function: maps a data-space x to a data-space y.
    ///   - isLogY: when true the value axis spans 0.1…100 logarithmically.
    ///   - lineWidth: stroke thickness in pixels.
    public static func render(size: (width: Int, height: Int) = (900, 640),
                              function: (Double) -> Double = { 0.5 + 4.0 / (1.0 + exp(-($0 - 5.0))) },
                              isLogY: Bool = false,
                              lineWidth: Int = 3) -> Chart {
        let w = size.width, h = size.height
        var pixels = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            pixels[i * 3] = background.r
            pixels[i * 3 + 1] = background.g
            pixels[i * 3 + 2] = background.b
        }

        let axX0 = 80, axX1 = w - 40
        let axY0 = h - 60, axY1 = 40
        let xMinV = 0.0, xMaxV = 10.0
        let yMinV = isLogY ? 0.1 : 0.0
        let yMaxV = isLogY ? 100.0 : 5.0

        @inline(__always)
        func toPixel(_ xv: Double, _ yv: Double) -> (Double, Double) {
            let tx = (xv - xMinV) / (xMaxV - xMinV)
            let ty: Double
            if isLogY {
                ty = (log10(yv) - log10(yMinV)) / (log10(yMaxV) - log10(yMinV))
            } else {
                ty = (yv - yMinV) / (yMaxV - yMinV)
            }
            return (Double(axX0) + tx * Double(axX1 - axX0),
                    Double(axY0) + ty * Double(axY1 - axY0))
        }

        @inline(__always)
        func setPixel(_ x: Int, _ y: Int, _ c: RGB8) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            let i = (y * w + x) * 3
            pixels[i] = c.r; pixels[i + 1] = c.g; pixels[i + 2] = c.b
        }

        for x in axX0...axX1 { setPixel(x, axY0, ink) }
        for y in axY1...axY0 { setPixel(axX0, y, ink) }

        let samples = 2000
        var curvePixels: [PixelPoint] = []
        curvePixels.reserveCapacity(samples + 1)
        for i in 0...samples {
            let xv = xMinV + (xMaxV - xMinV) * Double(i) / Double(samples)
            let (px, py) = toPixel(xv, function(xv))
            curvePixels.append(PixelPoint(x: px, y: py))
        }
        stroke(&pixels, width: w, height: h,
               points: curvePixels, color: curveColor, lineWidth: lineWidth)

        return Chart(buffer: BitmapBuffer(width: w, height: h, pixels: pixels),
                     curvePixels: curvePixels,
                     lineColor: curveColor,
                     backgroundColor: background,
                     axisX0: axX0, axisX1: axX1,
                     axisY0: axY0, axisY1: axY1,
                     xMinValue: xMinV, xMaxValue: xMaxV,
                     yMinValue: yMinV, yMaxValue: yMaxV,
                     isLogY: isLogY)
    }

    private static func stroke(_ pixels: inout [UInt8], width w: Int, height h: Int,
                               points: [PixelPoint], color: RGB8, lineWidth: Int) {
        let r = max(1.0, Double(lineWidth) / 2.0)
        let rr = Int(r.rounded(.up)) + 1
        let r2 = r * r + r

        var previous = points[0]
        for p in points {
            let segLength = ((p.x - previous.x) * (p.x - previous.x)
                             + (p.y - previous.y) * (p.y - previous.y)).squareRoot()
            let steps = max(1, Int(segLength * 4))
            for s in 0...steps {
                let t = Double(s) / Double(steps)
                let cx = previous.x + (p.x - previous.x) * t
                let cy = previous.y + (p.y - previous.y) * t
                let ix = Int(cx.rounded()), iy = Int(cy.rounded())
                for dy in -rr...rr {
                    for dx in -rr...rr {
                        let x = ix + dx, y = iy + dy
                        guard x >= 0, x < w, y >= 0, y < h else { continue }
                        if Double(dx * dx + dy * dy) <= r2 {
                            let i = (y * w + x) * 3
                            pixels[i] = color.r; pixels[i + 1] = color.g; pixels[i + 2] = color.b
                        }
                    }
                }
            }
            previous = p
        }
    }
}
