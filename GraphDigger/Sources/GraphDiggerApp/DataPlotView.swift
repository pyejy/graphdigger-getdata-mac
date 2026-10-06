import AppKit
import GDCore

/// The extracted data drawn in **its own coordinates** — FR-7.1.
///
/// This exists because the only quality check the app had was looking at the
/// marker dots on the scanned chart, and those dots sit *on* the curve they were
/// taken from: half a pixel of error is invisible there by construction. Plotted
/// against a data axis, the same error is a kink, a step, or a point that marched
/// off on its own — which is the whole reason the original GetData is criticised
/// for having no way to check its own output.
///
/// A separate window rather than a pane, deliberately: the toolbar has 13pt of
/// width to spare and the side panel is 272pt against a 1440pt screen, so there
/// is nowhere to put a plot that has to be *read*. A window can go beside the
/// canvas, which is what checking a curve against its source actually needs.
///
/// The drawing is deliberately dumb. Where a value lands and which numbers get
/// labelled are `PlotAxis`'s job, in `GDCore`, under test; this file only turns
/// fractions into rectangles.
final class DataPlotView: NSView {

    /// The document, as the canvas sees it. Setting it is the only way in.
    var state = ProjectState() { didSet { needsDisplay = true } }

    /// Leave room for tick labels. Measured once: the labels are numbers, and a
    /// number's width does not depend on the window.
    private static let marginLeft: CGFloat = 58
    private static let marginRight: CGFloat = 18
    private static let marginTop: CGFloat = 30
    private static let marginBottom: CGFloat = 30

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private var plotRect: NSRect {
        NSRect(x: Self.marginLeft,
               y: Self.marginTop,
               width: max(1, bounds.width - Self.marginLeft - Self.marginRight),
               height: max(1, bounds.height - Self.marginTop - Self.marginBottom))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let rect = plotRect
        guard let calibration = state.calibration else {
            drawNotice("还没有标定坐标系。\n点「标定坐标系」建立坐标系后，这里会画出取点结果。")
            return
        }

        // Only the curves the user can see on the canvas: this view is for
        // judging them, and a curve hidden there is hidden here too.
        let curves = state.lines.filter { $0.isVisible }
        let converted: [(line: CurveLine, points: [DataPoint], skipped: Int)] = curves.map { line in
            var points: [DataPoint] = []
            var skipped = 0
            for pixel in line.orderedPoints {
                if let data = try? calibration.data(fromPixel: pixel) { points.append(data) }
                else { skipped += 1 }
            }
            return (line, points, skipped)
        }

        let all = converted.flatMap(\.points)
        let skipped = converted.reduce(0) { $0 + $1.skipped }
        guard !all.isEmpty else {
            drawNotice(skipped > 0
                       ? "有 \(skipped) 个点落在这套坐标系画不出来的地方（对数轴上的非正值）。"
                       : "还没有取到点。\n用「区域取点」或「自动跟踪」取点后，这里会画出结果。")
            return
        }

        guard let xAxis = PlotAxis.covering(all.map(\.x),
                                            isLogarithmic: calibration.x.isLogarithmic),
              let yAxis = PlotAxis.covering(all.map(\.y),
                                            isLogarithmic: calibration.y.isLogarithmic),
              let xRange = PlotAxis(low: xAxis.low, high: xAxis.high,
                                    isLogarithmic: calibration.x.isLogarithmic),
              let yRange = PlotAxis(low: yAxis.low, high: yAxis.high,
                                    isLogarithmic: calibration.y.isLogarithmic)
        else {
            drawNotice("这批点的数值无法构成坐标轴。")
            return
        }

        func point(_ data: DataPoint) -> NSPoint? {
            guard let fx = xRange.fraction(data.x), let fy = yRange.fraction(data.y) else { return nil }
            return NSPoint(x: rect.minX + CGFloat(fx) * rect.width,
                           y: rect.maxY - CGFloat(fy) * rect.height)
        }

        drawAxes(rect: rect, x: xRange, y: yRange, frame: rect)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        // The active curve last, so it is on top where curves overlap — the same
        // precedence the canvas uses.
        let ordered = converted.sorted { a, b in
            (a.line.id == state.activeLineID ? 1 : 0) < (b.line.id == state.activeLineID ? 1 : 0)
        }
        for entry in ordered { drawCurve(entry.line, entry.points, point) }
        NSGraphicsContext.restoreGraphicsState()

        drawHeader(rect: rect, curves: curves.count, points: all.count, skipped: skipped)
    }

    private func drawCurve(_ line: CurveLine,
                           _ points: [DataPoint],
                           _ place: (DataPoint) -> NSPoint?) {
        // The sampled colour when there is one, else the curve's own palette
        // colour — the same choice the side panel's swatch makes, so the two
        // views agree about which curve is which. A curve can hold points without
        // ever having been sampled: 手工取点 needs no mask.
        let rgb = line.lineColor ?? line.color
        let colour = NSColor(red: CGFloat(rgb.r) / 255,
                             green: CGFloat(rgb.g) / 255,
                             blue: CGFloat(rgb.b) / 255,
                             alpha: 1)
        colour.setStroke()
        colour.setFill()

        let path = NSBezierPath()
        path.lineWidth = line.id == state.activeLineID ? 2 : 1.3
        path.lineJoinStyle = .round
        var drew = false
        for data in points {
            guard let p = place(data) else { continue }
            if drew { path.line(to: p) } else { path.move(to: p); drew = true }
        }
        if drew { path.stroke() }

        // Dots while they can still be told apart. A polyline shows the shape; the
        // dots show *where the points are*, and a wrong sample is usually wrong in
        // its spacing as much as its position.
        guard points.count <= 400 else { return }
        let radius: CGFloat = line.id == state.activeLineID ? 2.4 : 1.8
        for data in points {
            guard let p = place(data) else { continue }
            NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
        }
    }

    private func drawAxes(rect: NSRect, x: PlotAxis, y: PlotAxis, frame: NSRect) {
        let grid = NSColor.quaternaryLabelColor
        let axis = NSColor.tertiaryLabelColor

        grid.setStroke()
        let gridPath = NSBezierPath()
        gridPath.lineWidth = 1
        for tick in x.ticks {
            guard let f = x.fraction(tick) else { continue }
            let px = rect.minX + CGFloat(f) * rect.width
            gridPath.move(to: NSPoint(x: px, y: rect.minY))
            gridPath.line(to: NSPoint(x: px, y: rect.maxY))
        }
        for tick in y.ticks {
            guard let f = y.fraction(tick) else { continue }
            let py = rect.maxY - CGFloat(f) * rect.height
            gridPath.move(to: NSPoint(x: rect.minX, y: py))
            gridPath.line(to: NSPoint(x: rect.maxX, y: py))
        }
        gridPath.stroke()

        axis.setStroke()
        let framePath = NSBezierPath(rect: rect)
        framePath.lineWidth = 1
        framePath.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for tick in x.ticks {
            guard let f = x.fraction(tick) else { continue }
            let label = Self.number(tick) as NSString
            let size = label.size(withAttributes: attributes)
            let px = rect.minX + CGFloat(f) * rect.width - size.width / 2
            label.draw(at: NSPoint(x: px, y: rect.maxY + 4), withAttributes: attributes)
        }
        for tick in y.ticks {
            guard let f = y.fraction(tick) else { continue }
            let label = Self.number(tick) as NSString
            let size = label.size(withAttributes: attributes)
            let py = rect.maxY - CGFloat(f) * rect.height - size.height / 2
            label.draw(at: NSPoint(x: rect.minX - size.width - 6, y: py), withAttributes: attributes)
        }
    }

    private func drawHeader(rect: NSRect, curves: Int, points: Int, skipped: Int) {
        var text = "\(curves) 条曲线 · \(points) 个点"
        if skipped > 0 { text += " · \(skipped) 个点无法表示" }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        (text as NSString).draw(at: NSPoint(x: Self.marginLeft, y: 8), withAttributes: attributes)
    }

    private func drawNotice(_ text: String) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        string.draw(in: NSRect(x: 0, y: bounds.midY - size.height / 2,
                               width: bounds.width, height: size.height),
                    withAttributes: attributes)
    }

    /// A tick label: the value rounded to its own precision.
    ///
    /// `%g` rather than a fixed number of decimals, for two reasons. A range of
    /// 0…1 wants `0.6` and a range of 0…1000 wants `1000`, and no single decimal
    /// count gives both. And the values themselves are binary doubles — 0.6 is
    /// really 0.59999999999999998 — so anything that printed them raw would
    /// label a tick "0.6000000000000001".
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e6 || magnitude < 1e-4 {
            return String(format: "%.3g", value)
        }
        return String(format: "%g", value)
    }
}
