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
        /// Ground truth for the ruling grid, when the fixture drew one: the
        /// columns and rows the grid's strokes run along. Empty for a chart
        /// without a grid — and it is captured here rather than recomputed by
        /// the test, so a test cannot pass by repeating the generator's own
        /// arithmetic.
        public var gridColumns: [Int] = []
        public var gridRows: [Int] = []

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
                              lineWidth: Int = 3,
                              gridColumns: Int = 0,
                              gridRows: Int = 0,
                              gridColor: RGB8? = nil,
                              gridLineWidth: Int = 1) -> Chart {
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

        // The ruling grid, when asked for: equal-spaced thin lines inside the
        // plot area, drawn *under* the curve the way a printed figure has them.
        // The colour defaults to the curve's own, because that is the case that
        // matters — a grid in a distinct colour is already excluded by the
        // distance and hue gates, and would let the geometric pass look better
        // than it is.
        var gridColumnCentres: [Int] = []
        var gridRowCentres: [Int] = []
        if gridColumns > 0 || gridRows > 0 {
            let c = gridColor ?? curveColor
            if gridColumns > 0 {
                for k in 1...gridColumns {
                    let x = axX0 + (axX1 - axX0) * k / (gridColumns + 1)
                    gridColumnCentres.append(x)
                    for y in axY1...axY0 {
                        for d in 0..<max(1, gridLineWidth) { setPixel(x + d, y, c) }
                    }
                }
            }
            if gridRows > 0 {
                for k in 1...gridRows {
                    let y = axY1 + (axY0 - axY1) * k / (gridRows + 1)
                    gridRowCentres.append(y)
                    for x in axX0...axX1 {
                        for d in 0..<max(1, gridLineWidth) { setPixel(x, y + d, c) }
                    }
                }
            }
        }

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
                     isLogY: isLogY,
                     gridColumns: gridColumnCentres,
                     gridRows: gridRowCentres)
    }

    /// 带误差棒的合成图(B-2 的夹具):每个数据点一根竖棒,上下各一根横杠。
    ///
    /// 真值逐点给,而不是让测试自己按公式再算一遍 —— 那等于把生成器的算术抄进
    /// 断言里,生成器错了测试跟着错。
    public struct ErrorBarChart: Sendable {
        public var buffer: BitmapBuffer
        /// 数据点中心(像素),也是"已经取到的点"。
        public var points: [PixelPoint]
        /// 每个点向上的误差(像素),与 `points` 一一对应。
        public var upPixels: [Double]
        /// 每个点向下的误差(像素)。
        public var downPixels: [Double]
        public var lineColor: RGB8
        public var backgroundColor: RGB8
        public var axisX0: Int
        public var axisX1: Int
        public var axisY0: Int
        public var axisY1: Int
        public var xMinValue: Double
        public var xMaxValue: Double
        public var yMinValue: Double
        public var yMaxValue: Double

        public var calibration: CalibrationMap {
            CalibrationMap(
                x: AxisCalibration(pixelMin: Double(axisX0), valueMin: xMinValue,
                                   pixelMax: Double(axisX1), valueMax: xMaxValue),
                y: AxisCalibration(pixelMin: Double(axisY0), valueMin: yMinValue,
                                   pixelMax: Double(axisY1), valueMax: yMaxValue))
        }
    }

    /// 画一张带误差棒的散点图。
    ///
    /// - `up` / `down` 按点序号给出误差长度(像素),默认对称 —— 不对称是真实
    ///   存在的情形,所以由调用方决定,不写死成对称。
    /// - `withErrorBars: false` 画纯散点:同一个夹具就能兼作"不许误报"的对照,
    ///   比再造一张图更严 —— 除了棒,两者逐像素相同。
    public static func renderErrorBars(
        size: (width: Int, height: Int) = (900, 640),
        count: Int = 8,
        up: (Int) -> Double = { _ in 26 },
        down: (Int) -> Double = { _ in 26 },
        withErrorBars: Bool = true,
        barColor: RGB8? = nil,
        capHalfWidth: Int = 5,
        stemWidth: Int = 2,
        markerDiameter: Int = 9) -> ErrorBarChart {
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
        let yMinV = 0.0, yMaxV = 5.0

        @inline(__always)
        func setPixel(_ x: Int, _ y: Int, _ c: RGB8) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            let i = (y * w + x) * 3
            pixels[i] = c.r; pixels[i + 1] = c.g; pixels[i + 2] = c.b
        }
        @inline(__always)
        func fillRect(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, _ c: RGB8) {
            guard x1 >= x0, y1 >= y0 else { return }
            for y in y0...y1 { for x in x0...x1 { setPixel(x, y, c) } }
        }

        for x in axX0...axX1 { setPixel(x, axY0, ink) }
        for y in axY1...axY0 { setPixel(axX0, y, ink) }

        // 点沿一条缓慢上行的曲线分布(实验图常见的样子)。
        var points: [PixelPoint] = []
        var ups: [Double] = []
        var downs: [Double] = []
        for i in 0..<count {
            let t = Double(i) / Double(max(1, count - 1))
            let px = Int((Double(axX0) + 40 + t * Double(axX1 - axX0 - 80)).rounded())
            let value = 1.0 + 2.4 * t
            let py = Int((Double(axY0) - (value - yMinV) / (yMaxV - yMinV)
                                          * Double(axY0 - axY1)).rounded())
            let upLen = up(i), downLen = down(i)
            points.append(PixelPoint(x: Double(px), y: Double(py)))
            ups.append(upLen)
            downs.append(downLen)

            if withErrorBars {
                // 棒身:以点为中线的一段竖线(棒身宽度从点的中心向两侧铺开)。
                // 棒的颜色可与曲线不同 —— 彩色曲线配黑色误差棒是真实图里最常见
                // 的组合之一,也正是"一个都没找到"的头号原因。
                let ink = barColor ?? curveColor
                let half = max(0, (stemWidth - 1) / 2)
                let top = py - Int(upLen.rounded())
                let bottom = py + Int(downLen.rounded())
                fillRect(px - half, px + half, top, bottom, ink)
                // 上下横杠。
                fillRect(px - capHalfWidth, px + capHalfWidth, top, top + 1, ink)
                fillRect(px - capHalfWidth, px + capHalfWidth, bottom - 1, bottom, ink)
            }
            // 标记画在最后:它盖住棒身中段,与真实图一致(点压在棒上)。
            let r = markerDiameter / 2
            for dy in -r...r {
                for dx in -r...r where dx * dx + dy * dy <= r * r {
                    setPixel(px + dx, py + dy, scatterColor)
                }
            }
        }

        return ErrorBarChart(buffer: BitmapBuffer(width: w, height: h, pixels: pixels),
                             points: points, upPixels: ups, downPixels: downs,
                             lineColor: scatterColor, backgroundColor: background,
                             axisX0: axX0, axisX1: axX1, axisY0: axY0, axisY1: axY1,
                             xMinValue: xMinV, xMaxValue: xMaxV,
                             yMinValue: yMinV, yMaxValue: yMaxV)
    }

    /// The symbol shapes a synthetic scatter can draw.
    ///
    /// More than one because a matcher that passes against circles alone has not
    /// been tested: a circle's bounding-box centre *is* its ink centre and its
    /// box is filled 0.785, so both of the obvious wrong implementations — box
    /// centre instead of centre of mass, and a fill-ratio filter tuned to a disc
    /// — pass on circles and fail on everything else.
    public enum MarkerShape: String, Sendable, CaseIterable {
        case circle
        case square
        case triangle
    }

    /// A scatter plot: disconnected glyphs, and **no** line between them.
    public struct ScatterChart: Sendable {
        public var buffer: BitmapBuffer
        /// Where each symbol's **ink** was drawn, in pixel space — the ground
        /// truth. For a triangle this is its centroid, which is *not* the centre
        /// of the box it occupies; recording the box centre here would bake the
        /// classic mistake into the fixture that exists to catch it.
        public var markerCentres: [PixelPoint]
        public var markerShapes: [MarkerShape]
        public var markerColor: RGB8
        public var backgroundColor: RGB8
        public var markerDiameter: Int
        /// Where a legend key of the same colour was drawn, when one was asked
        /// for — the thing a matcher must *not* return as a data point.
        public var legendCentre: PixelPoint?
        public var legendSide: Int
        public var axisX0: Int
        public var axisX1: Int
        public var axisY0: Int
        public var axisY1: Int
        public var xMinValue: Double
        public var xMaxValue: Double
        public var yMinValue: Double
        public var yMaxValue: Double
        public var isLogY: Bool

        /// Calibration implied by the frame the generator drew.
        public var calibration: CalibrationMap {
            CalibrationMap(
                x: AxisCalibration(pixelMin: Double(axisX0), valueMin: xMinValue,
                                   pixelMax: Double(axisX1), valueMax: xMaxValue),
                y: AxisCalibration(pixelMin: Double(axisY0), valueMin: yMinValue,
                                   pixelMax: Double(axisY1), valueMax: yMaxValue,
                                   isLogarithmic: isLogY))
        }
    }

    /// Colour of the synthetic scatter's symbols. The same red the line charts
    /// use, so a mask built for one is a mask for the other.
    public static let scatterColor = RGB8(r: 200, g: 45, b: 45)

    /// Draws a scatter plot: `count` symbols at deterministic positions, on the
    /// same axis frame as the line charts.
    ///
    /// The y values come from a hash of x rather than from a random number
    /// generator. The fixture has to render identically on every machine and in
    /// every run — a corpus that shifts underfoot turns a failing test into a
    /// question about the seed — while still looking like measurements rather
    /// than a curve, which is the property the matcher is being tested against.
    ///
    /// - Parameters:
    ///   - legendSwatch: draws a key of the same colour at three times the marker
    ///     size, the way a figure legend does. A matcher that does not filter by
    ///     size returns it as a data point.
    ///   - tintedAxes: draws the axis rules in the marker colour. A matcher that
    ///     does not filter by shape returns their segments as data points.
    public static func renderScatter(size: (width: Int, height: Int) = (900, 640),
                                     count: Int = 40,
                                     markerDiameter: Int = 11,
                                     shapes: [MarkerShape] = [.circle],
                                     isLogY: Bool = false,
                                     legendSwatch: Bool = false,
                                     tintedAxes: Bool = false) -> ScatterChart {
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

        let axisColor = tintedAxes ? scatterColor : ink
        for x in axX0...axX1 { setPixel(x, axY0, axisColor) }
        for y in axY1...axY0 { setPixel(axX0, y, axisColor) }

        // The symbols are round to the pixel so each one is exactly symmetric
        // about its centre: the matcher's centroid then has to come out equal to
        // the recorded centre, and a quarter-pixel bias cannot hide in the
        // fixture's own rounding.
        let shapes = shapes.isEmpty ? [.circle] : shapes
        var centres: [PixelPoint] = []
        var drawnShapes: [MarkerShape] = []
        let samples = max(1, count)
        for i in 0..<samples {
            let tx = samples == 1 ? 0.5 : Double(i) / Double(samples - 1)
            let xv = xMinV + (xMaxV - xMinV) * (0.05 + 0.90 * tx)
            // Deterministic hash in [0, 1).
            let hsh = sin(xv * 12.9898 + 4.1414) * 43758.5453
            let unit = hsh - hsh.rounded(.down)
            let yv = isLogY
                ? yMinV * pow(yMaxV / yMinV, 0.12 + 0.76 * unit)
                : yMinV + (yMaxV - yMinV) * (0.12 + 0.76 * unit)
            let (px, py) = toPixel(xv, yv)
            let shape = shapes[i % shapes.count]
            let centre = (x: Double(Int(px.rounded())), y: Double(Int(py.rounded())))
            fillMarker(&pixels, width: w, height: h,
                       centre: centre, diameter: markerDiameter,
                       shape: shape, color: scatterColor)
            centres.append(inkCentre(of: shape, centre: centre, diameter: markerDiameter))
            drawnShapes.append(shape)
        }

        var legendCentre: PixelPoint?
        let legendSide = markerDiameter * 3
        if legendSwatch {
            let centre = (x: Double(axX1 - legendSide), y: Double(axY1 + legendSide))
            fillMarker(&pixels, width: w, height: h, centre: centre,
                       diameter: legendSide, shape: .square, color: scatterColor)
            legendCentre = PixelPoint(x: centre.x, y: centre.y)
        }

        return ScatterChart(buffer: BitmapBuffer(width: w, height: h, pixels: pixels),
                            markerCentres: centres,
                            markerShapes: drawnShapes,
                            markerColor: scatterColor,
                            backgroundColor: background,
                            markerDiameter: markerDiameter,
                            legendCentre: legendCentre,
                            legendSide: legendSide,
                            axisX0: axX0, axisX1: axX1,
                            axisY0: axY0, axisY1: axY1,
                            xMinValue: xMinV, xMaxValue: xMaxV,
                            yMinValue: yMinV, yMaxValue: yMaxV,
                            isLogY: isLogY)
    }

    /// The centre of the ink a marker of this shape puts down.
    ///
    /// A circle and a square are symmetric about the point they are drawn at; a
    /// triangle is not — its mass sits a third of the way up from the base, one
    /// sixth of the height above its box centre. Recording the box centre for all
    /// three would make the fixture agree with the wrong implementation.
    private static func inkCentre(of shape: MarkerShape, centre: (x: Double, y: Double),
                                  diameter: Int) -> PixelPoint {
        switch shape {
        case .circle, .square:
            return PixelPoint(x: centre.x, y: centre.y)
        case .triangle:
            return PixelPoint(x: centre.x, y: centre.y + Double(diameter) / 6)
        }
    }

    private static func fillMarker(_ pixels: inout [UInt8], width w: Int, height h: Int,
                                   centre: (x: Double, y: Double), diameter: Int,
                                   shape: MarkerShape, color: RGB8) {
        let half = Double(max(1, diameter)) / 2
        let cx = centre.x, cy = centre.y
        let minX = Int((cx - half).rounded(.down)), maxX = Int((cx + half).rounded(.up))
        let minY = Int((cy - half).rounded(.down)), maxY = Int((cy + half).rounded(.up))

        for y in minY...maxY {
            guard y >= 0, y < h else { continue }
            for x in minX...maxX {
                guard x >= 0, x < w else { continue }
                let dx = Double(x) - cx, dy = Double(y) - cy
                let inside: Bool
                switch shape {
                case .circle:
                    inside = dx * dx + dy * dy <= half * half
                case .square:
                    inside = abs(dx) <= half && abs(dy) <= half
                case .triangle:
                    // Apex up, base along the bottom of the box. Inside when the
                    // point is below both edges and above the base.
                    let apex = Point2(x: cx, y: cy - half)
                    let left = Point2(x: cx - half, y: cy + half)
                    let right = Point2(x: cx + half, y: cy + half)
                    inside = Self.insideTriangle(x: Double(x), y: Double(y),
                                                 a: apex, b: left, c: right)
                }
                if inside {
                    let i = (y * w + x) * 3
                    pixels[i] = color.r; pixels[i + 1] = color.g; pixels[i + 2] = color.b
                }
            }
        }
    }

    private struct Point2 { var x: Double; var y: Double }

    /// Sign-of-area test: inside when the point is on the same side of all three
    /// directed edges. Written out rather than using a geometry library because
    /// `GDCore` has none, and one triangle does not justify adding one.
    private static func insideTriangle(x: Double, y: Double,
                                       a: Point2, b: Point2, c: Point2) -> Bool {
        func cross(_ p: Point2, _ q: Point2, _ r: Point2) -> Double {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let d1 = cross(a, b, Point2(x: x, y: y))
        let d2 = cross(b, c, Point2(x: x, y: y))
        let d3 = cross(c, a, Point2(x: x, y: y))
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
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
