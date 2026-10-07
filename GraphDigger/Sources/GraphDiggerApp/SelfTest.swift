import AppKit
import Foundation
import GDCore
import UniformTypeIdentifiers

/// End-to-end check of the shipping binary: synthetic chart in, exported data
/// out, with the accuracy target from the requirements doc asserted.
///
/// This exercises the same code path the UI drives — mask, calibration,
/// digitising, export — so a regression that only shows up once the pieces are
/// wired together is caught without launching the GUI.
enum SelfTest {

    private static var failures = 0

    private static func check(_ label: String, _ passed: Bool, _ detail: String = "") {
        let mark = passed ? "  ok  " : " FAIL "
        print("[\(mark)] \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
        if !passed { failures += 1 }
    }

    static func run() -> Bool {
        print("GraphDigger selftest")
        print(String(repeating: "─", count: 62))

        let chart = SyntheticChart.render()
        let mask = ForegroundMask.build(from: chart.buffer,
                                        lineColor: chart.lineColor, tolerance: 60)
        let maskCount = mask.bits.filter { $0 }.count
        check("前景掩膜", maskCount > 1_000 && maskCount < mask.bits.count / 5,
              "\(maskCount) 个前景像素")

        let calibration = chart.calibration

        // --- calibration round trip -------------------------------------
        var roundTripOK = true
        for pixel in chart.curvePixels where chart.curvePixels.firstIndex(of: pixel).map({ $0 % 97 == 0 }) == true {
            guard let back = try? calibration.pixel(fromData: try calibration.data(fromPixel: pixel)) else {
                roundTripOK = false; break
            }
            if abs(back.x - pixel.x) > 1e-6 || abs(back.y - pixel.y) > 1e-6 { roundTripOK = false; break }
        }
        check("标定双向往返", roundTripOK, "误差 < 1e-6 像素")

        // --- area digitise accuracy -------------------------------------
        let rect = PixelRect(x0: chart.axisX0 + 2, y0: chart.axisY1,
                             x1: chart.axisX1, y1: chart.axisY0 - 2)
        let points = AreaDigitizer.digitize(mask: mask, rect: rect, dx: 8)
        check("区域取点产出", points.count > 40, "\(points.count) 个点")

        let errors = yErrors(points, chart: chart)
        let p95 = percentile(errors, 95)
        check("区域取点精度 p95 ≤ 0.5%", p95 <= 0.005,
              String(format: "p95 = %.3f%%", p95 * 100))

        // --- trace -------------------------------------------------------
        do {
            let traced = try TraceDigitizer.trace(mask: mask, from: chart.curvePixels[0])
            let end = traced.points.last ?? PixelPoint(x: -1, y: -1)
            let truth = chart.curvePixels.last!
            let close = abs(end.x - truth.x) < 8 && abs(end.y - truth.y) < 8
            check("自动跟踪走完全程", close && traced.branchPoint == nil,
                  "\(traced.points.count) 个点,终点偏差 (\(Int(end.x - truth.x)), \(Int(end.y - truth.y)))")
        } catch {
            check("自动跟踪走完全程", false, "抛出 \(error)")
        }

        // --- export ------------------------------------------------------
        // Points go onto a curve that carries the chart's colour, which is how
        // the app now stores per-curve state.
        var state = ProjectState(calibration: calibration)
        state.defaultBackgroundColor = chart.backgroundColor
        let lineID = state.addLine(color: chart.lineColor)
        state.setLineColor(chart.lineColor, for: lineID)
        state.append(points: points, usingDefaultColor: chart.lineColor)
        do {
            let csv = try Exporter.text(for: state.lines, calibration: calibration, format: .csv)
            let rows = csv.split(separator: "\n").count
            check("CSV 导出", rows == points.count + 1, "\(rows) 行")
        } catch {
            check("CSV 导出", false, "抛出 \(error)")
        }

        do {
            let xml = try Exporter.text(for: state.lines, calibration: calibration, format: .xml)
            check("XML 导出可解析", XMLParser(data: Data(xml.utf8)).parse())
        } catch {
            check("XML 导出可解析", false, "抛出 \(error)")
        }

        // The workbook leaves as bytes, not text, so it is checked as bytes: the
        // ZIP prologue a reader looks for and the parts an OOXML package must
        // contain. What is *inside* those parts is asserted in `XLSXTests`,
        // against the same writer.
        do {
            let workbook = try Exporter.data(for: state.lines,
                                             calibration: calibration,
                                             format: .xlsx)
            let parts = ["[Content_Types].xml", "xl/workbook.xml", "xl/worksheets/sheet1.xml"]
            let missing = parts.filter { workbook.range(of: Data($0.utf8)) == nil }
            let startsWithZip = Array(workbook.prefix(4)) == [0x50, 0x4B, 0x03, 0x04]
            let endsWithDirectory = workbook.count > 22
                && Array(workbook.suffix(22).prefix(4)) == [0x50, 0x4B, 0x05, 0x06]
            let ok = startsWithZip && endsWithDirectory && missing.isEmpty
            check("XLSX 导出是真 ZIP 容器,OOXML 部件齐全", ok,
                  ok ? "\(workbook.count) 字节 · 本地头 PK\u{03}\u{04} · 部件 \(parts.count) 个齐全"
                     : "ZIP头=\(startsWithZip) 结束记录=\(endsWithDirectory) 缺=\(missing)")

            do {
                _ = try Exporter.text(for: state.lines, calibration: calibration, format: .xlsx)
                check("XLSX 不会被文本通道误当成字符串", false, "文本通道竟然答应了")
            } catch ExportError.notATextFormat {
                check("XLSX 不会被文本通道误当成字符串", true)
            }
        } catch {
            check("XLSX 导出是真 ZIP 容器,OOXML 部件齐全", false, "抛出 \(error)")
        }

        // --- PNG round trip through the real decode path -------------------
        // Everything above used the in-memory buffer. This leg goes out to a
        // PNG and back through the same NSImage/CGImage conversion the app uses
        // when the user opens a file, which is where a 24-vs-32-bit mistake in
        // the bitmap context would show up.
        if let cgImage = SampleChartWriter.makeCGImage(from: chart.buffer) {
            let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
            if let png, let decoded = NSImage(data: png),
               let decodedCG = decoded.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let roundTrip = CanvasView.makeBuffer(from: decodedCG) {
                check("PNG 解码尺寸一致",
                      roundTrip.width == chart.buffer.width && roundTrip.height == chart.buffer.height,
                      "\(roundTrip.width)x\(roundTrip.height)")

                // The decoded image must yield the same mask, proving colour
                // sampling survives the round trip.
                let decodedMask = ForegroundMask.build(from: roundTrip,
                                                       lineColor: chart.lineColor, tolerance: 60)
                let decodedCount = decodedMask.bits.filter { $0 }.count
                check("PNG 往返后掩膜一致",
                      abs(decodedCount - maskCount) <= max(10, maskCount / 100),
                      "\(maskCount) -> \(decodedCount)")

                // And the sample pixel must read back as the curve colour.
                let sampleX = Int(chart.curvePixels[chart.curvePixels.count / 2].x)
                let sampleY = Int(chart.curvePixels[chart.curvePixels.count / 2].y)
                let sampled = roundTrip.color(atX: sampleX, y: sampleY)
                check("取色命中曲线颜色",
                      sampled.r > 150 && sampled.g < 90 && sampled.b < 90,
                      "RGB(\(sampled.r), \(sampled.g), \(sampled.b))")
            } else {
                check("PNG 解码尺寸一致", false, "PNG 编码或解码失败")
            }
        } else {
            check("PNG 解码尺寸一致", false, "无法从缓冲区构建 CGImage")
        }

        // --- calibration ticks -------------------------------------------
        // The overlay's whole job is making a wrong calibration visible, so the
        // ticks must land inside the axis and round-trip through the mapping.
        let xTicks = calibration.x.ticks(overPixelRange: Double(chart.axisX0)...Double(chart.axisX1))
        let yTicks = calibration.y.ticks(overPixelRange: Double(chart.axisY1)...Double(chart.axisY0))
        check("X 轴刻度生成", xTicks.count >= 3, "\(xTicks.count) 个刻度")
        check("Y 轴刻度生成", yTicks.count >= 3, "\(yTicks.count) 个刻度")

        let ticksInRange = xTicks.allSatisfy {
            $0.pixel >= Double(chart.axisX0) - 0.001 && $0.pixel <= Double(chart.axisX1) + 0.001
        }
        check("刻度落在轴范围内", ticksInRange)

        let ticksRoundTrip = xTicks.allSatisfy { tick in
            guard let value = try? calibration.x.value(atPixel: tick.pixel) else { return false }
            return abs(value - tick.value) < 1e-6
        }
        check("刻度值与像素一致", ticksRoundTrip)

        // The value axis is stored bottom-to-top; increasing value must mean a
        // decreasing pixel row, or the overlay would draw mirrored.
        let yOrdered = yTicks.sorted { $0.value < $1.value }
        let yDescending = zip(yOrdered, yOrdered.dropFirst()).allSatisfy { $1.pixel < $0.pixel }
        check("Y 轴方向正确(值增而行号减)", yDescending)

        // The four-click flow, including the right-to-left case that used to
        // be undefined: direction must follow the clicked pixels.
        var anchorState = ProjectState()
        _ = anchorState.applyCalibration(anchors: CalibrationAnchors(
                                             xStart: PixelPoint(x: 900, y: 600),
                                             xEnd: PixelPoint(x: 100, y: 600),
                                             yStart: PixelPoint(x: 900, y: 600),
                                             yEnd: PixelPoint(x: 900, y: 40)),
                                         xStartValue: 0, xEndValue: 10,
                                         yStartValue: 0, yEndValue: 5,
                                         xIsLogarithmic: false, yIsLogarithmic: false)
        let fourAnchorOK = (try? anchorState.calibration?.x.value(atPixel: 900)) == 0
            && (try? anchorState.calibration?.x.value(atPixel: 100)) == 10
            && (try? anchorState.calibration?.y.value(atPixel: 40)) == 5
        check("四点标定 + 反向绘制", fourAnchorOK)
        check("锚点数量为 4", anchorState.calibrationAnchors?.ordered.count == 4)

        // The chart from the screenshot: an X rule along the bottom and a Y rule
        // up the left, with *different* start rows and columns. The old shared
        // origin could only describe this by mis-calibrating one of the two.
        var splitState = ProjectState()
        let split = CalibrationAnchors(xStart: PixelPoint(x: 86, y: 488),
                                       xEnd: PixelPoint(x: 700, y: 488),
                                       yStart: PixelPoint(x: 90, y: 560),
                                       yEnd: PixelPoint(x: 90, y: 100))
        _ = splitState.applyCalibration(anchors: split,
                                        xStartValue: 0, xEndValue: 1,
                                        yStartValue: 0, yEndValue: 10,
                                        xIsLogarithmic: false, yIsLogarithmic: false)
        // Each axis reads only its own anchor's own coordinate, so the X rule's
        // row (488) has no bearing on the Y mapping and vice versa.
        let splitOK = (try? splitState.calibration?.x.value(atPixel: 86)) == 0
            && (try? splitState.calibration?.x.value(atPixel: 700)) == 1
            && (try? splitState.calibration?.y.value(atPixel: 560)) == 0
            && (try? splitState.calibration?.y.value(atPixel: 100)) == 10
        check("两轴起点不重合也能标定", splitOK)

        // A non-zero origin, i.e. an offset axis.
        var offsetState = ProjectState()
        _ = offsetState.applyCalibration(anchors: CalibrationAnchors(
                                             xStart: PixelPoint(x: 50, y: 500),
                                             xEnd: PixelPoint(x: 850, y: 500),
                                             yStart: PixelPoint(x: 50, y: 500),
                                             yEnd: PixelPoint(x: 50, y: 100)),
                                         xStartValue: 100, xEndValue: 200,
                                         yStartValue: 273, yEndValue: 373,
                                         xIsLogarithmic: false, yIsLogarithmic: false)
        let offsetOK = (try? offsetState.calibration?.y.value(atPixel: 500)) == 273
            && (try? offsetState.calibration?.y.value(atPixel: 100)) == 373
        check("非零原点(偏移坐标轴)", offsetOK)

        // --- layout: the toolbar must survive a fullscreen resize ---------
        // Regression: autoresizing masks pinned the toolbar by its top margin,
        // so growing the window slid it into the canvas, which is drawn later
        // and therefore on top — the buttons vanished in fullscreen. This
        // exercises the real MainLayout used by the app.
        let layoutContainer = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 840))
        let layoutToolbar = NSView(frame: .zero)
        let layoutCanvas = NSView(frame: .zero)
        MainLayout.install(container: layoutContainer, toolbar: layoutToolbar,
                           canvas: layoutCanvas)

        var layoutOK = true
        var layoutDetail = ""
        for height in [840.0, 1_080.0, 1_440.0] {
            layoutContainer.frame = NSRect(x: 0, y: 0, width: 1_200, height: height)
            layoutContainer.layoutSubtreeIfNeeded()

            // Toolbar flush against the top edge...
            let topGap = layoutContainer.bounds.height - layoutToolbar.frame.maxY
            // ...filling the width, and never overlapping the canvas.
            let fullWidth = abs(layoutToolbar.frame.width - 1_200) < 0.5
            let overlaps = layoutToolbar.frame.intersects(layoutCanvas.frame)
            if abs(topGap) > 0.5 || overlaps || !fullWidth {
                layoutOK = false
                layoutDetail = "高 \(Int(height)): 顶部间隙 \(Int(topGap)), "
                    + "宽 \(Int(layoutToolbar.frame.width)), 与画布重叠 \(overlaps)"
                break
            }
        }
        check("全屏改变窗口高度时工具栏不跑位", layoutOK, layoutDetail)

        // --- fit ----------------------------------------------------------
        // 适配窗口 must re-centre, and report that it did something.
        var fitTransform = ViewTransform()
        fitTransform.fit(imageWidth: 900, imageHeight: 640, viewWidth: 1_000, viewHeight: 800)
        fitTransform.pan(by: CGPoint(x: 120, y: -80))
        let panned = fitTransform
        fitTransform.fit(imageWidth: 900, imageHeight: 640, viewWidth: 1_000, viewHeight: 800)
        check("适配窗口会重新居中", fitTransform != panned)

        let centredX = fitTransform.offset.x + 900 * fitTransform.scale / 2
        let centredY = fitTransform.offset.y + 640 * fitTransform.scale / 2
        check("适配后图像居中",
              abs(centredX - 500) < 0.5 && abs(centredY - 400) < 0.5,
              String(format: "中心 (%.1f, %.1f) 应为 (500, 400)", centredX, centredY))

        // --- toolbar hit testing ------------------------------------------
        // Regression: the status/summary labels used to overlap the right-hand
        // buttons and swallowed their clicks, so 适配窗口 and 导出 were dead.
        // Every toolbar control must be reachable at its own centre.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 88))
        let toolbar = ToolbarView(frame: container.bounds)
        container.addSubview(toolbar)
        // Undo and redo enabled, so the icon-only control is in the reachability
        // sweep below along with the rest: its segments are the controls here
        // whose contents are not text, and a label overlapping *them* would be
        // just as dead.
        toolbar.update(isLoadingEnabled: true, canExport: true, canUndo: true, canRedo: true)
        container.layoutSubtreeIfNeeded()

        // Checked at the window's minimum width — the tightest real layout, and
        // therefore where an overlap would actually bite.
        var blocked: [String] = []
        var buttons = 0
        for width in [toolbar.requiredWidth, toolbar.requiredWidth + 60, 1_600] {
            container.frame = NSRect(x: 0, y: 0, width: width, height: 88)
            toolbar.frame = container.bounds
            container.layoutSubtreeIfNeeded()

            // Every control, and for the segmented 撤销/恢复 each *segment*
            // separately: the two halves have to be reachable as two targets, not
            // merely as one view — a click anywhere on the pair that landed on
            // the wrong half would undo when the user meant to redo.
            var probes: [(name: String, point: NSPoint, expect: NSView)] = []
            for subview in toolbar.subviews {
                if let segmented = subview as? NSSegmentedControl {
                    // The two icon segments auto-size evenly, so the halves of
                    // the bounds are where the two segments are — no need for the
                    // per-segment rect the SDK does not expose here.
                    for segment in 0..<segmented.segmentCount {
                        let width = segmented.bounds.width / CGFloat(segmented.segmentCount)
                        probes.append((segment == 0 ? "撤销段" : "恢复段",
                                       toolbar.convert(NSPoint(x: width * (CGFloat(segment) + 0.5),
                                                              y: segmented.bounds.midY),
                                                       from: segmented),
                                       segmented))
                    }
                } else if let button = subview as? NSButton, button.isEnabled {
                    let name = button.title.isEmpty
                        ? "图标按钮" : button.title.trimmingCharacters(in: .whitespaces)
                    probes.append((name, NSPoint(x: button.frame.midX, y: button.frame.midY), button))
                }
            }
            if width == toolbar.requiredWidth { buttons = probes.count }

            for probe in probes {
                // Dispatch from the container: hitTest takes a point in the
                // receiver's superview coordinates, so this is how AppKit itself
                // decides which view receives a click.
                let centre = container.convert(probe.point, from: toolbar)
                if container.hitTest(centre) !== probe.expect {
                    let entry = "\(probe.name) @宽\(Int(width))"
                    if !blocked.contains(entry) { blocked.append(entry) }
                }
            }
        }
        check("工具栏按钮数量", buttons >= 10, "\(buttons) 个按钮")
        check("每个按钮都能被点中(最小宽度下)", blocked.isEmpty,
              blocked.isEmpty ? "" : "被挡住: \(blocked.joined(separator: ", "))")

        // The buttons used to be sized from an estimated text width, which
        // under-sized every one of them: 标定坐标系 was given 97pt for contents
        // that need 106, so the label was clipped. Ask each cell what it needs
        // and compare, which is the failure the user could see.
        container.frame = NSRect(x: 0, y: 0, width: 1_600, height: 88)
        toolbar.frame = container.bounds
        container.layoutSubtreeIfNeeded()
        var clipped: [String] = []
        for subview in toolbar.subviews {
            guard let button = subview as? NSButton, !button.title.isEmpty else { continue }
            let needed = button.cell!.cellSize(forBounds: NSRect(x: 0, y: 0,
                                                                 width: 10_000,
                                                                 height: button.bounds.height)).width
            if needed > button.bounds.width + 0.5 {
                clipped.append("\(button.title.trimmingCharacters(in: .whitespaces)) "
                    + "少 \(Int((needed - button.bounds.width).rounded()))pt")
            }
        }
        check("工具栏按钮不会裁掉自己的文字", clipped.isEmpty,
              clipped.isEmpty ? "" : clipped.joined(separator: ", "))

        // Labels must never intercept clicks, at any window width.
        var labelsBlocking = 0
        for width in [toolbar.requiredWidth, 980.0, 1_600.0] {
            container.frame = NSRect(x: 0, y: 0, width: width, height: 88)
            toolbar.frame = container.bounds
            container.layoutSubtreeIfNeeded()
            for label in toolbar.subviews.compactMap({ $0 as? NSTextField }) {
                if label.hitTest(NSPoint(x: label.frame.midX, y: label.frame.midY)) != nil {
                    labelsBlocking += 1
                }
            }
        }
        check("文字标签不拦截点击", labelsBlocking == 0)

        // The row may be as wide as it likes only up to the point where the
        // window it forces no longer fits the smallest screen the app supports.
        // An absolute cap here would be a number nobody could justify — the old
        // one was 1200, chosen to sit just under the row's then-current width.
        // Deriving it means the check moves when `narrowestScreenWidth` does.
        let derivedWindow = MainLayout.windowMinimumWidth(toolbarWidth: toolbar.requiredWidth)
        check("工具栏宽度自洽", derivedWindow <= MainLayout.narrowestScreenWidth,
              "窗口 \(Int(derivedWindow)) pt / 屏幕 \(Int(MainLayout.narrowestScreenWidth)) pt")

        // --- view transform ----------------------------------------------
        var transform = ViewTransform()
        transform.fit(imageWidth: chart.buffer.width, imageHeight: chart.buffer.height,
                      viewWidth: 1200, viewHeight: 800)
        let probe = PixelPoint(x: 321, y: 123)
        let back = transform.imagePoint(fromView: transform.viewPoint(fromImage: probe))
        check("视图变换往返", abs(back.x - probe.x) < 1e-9 && abs(back.y - probe.y) < 1e-9)

        var zoomed = transform
        let anchor = CGPoint(x: 400, y: 300)
        let anchorImageBefore = zoomed.imagePoint(fromView: anchor)
        zoomed.zoom(by: 2.0, around: anchor)
        let anchorImageAfter = zoomed.imagePoint(fromView: anchor)
        check("缩放锚点不动",
              abs(anchorImageBefore.x - anchorImageAfter.x) < 1e-6
              && abs(anchorImageBefore.y - anchorImageAfter.y) < 1e-6)

        // --- background detection ------------------------------------------
        // The whole point is that the user never has to click the background:
        // it is sampled once on load and inherited by every new curve.
        if let detected = BackgroundDetector.detect(in: chart.buffer) {
            let truth = chart.backgroundColor
            let distance = abs(Int(detected.r) - Int(truth.r))
                + abs(Int(detected.g) - Int(truth.g))
                + abs(Int(detected.b) - Int(truth.b))
            check("背景色自动检测", distance <= 6,
                  "RGB(\(detected.r),\(detected.g),\(detected.b)) 应为 RGB(\(truth.r),\(truth.g),\(truth.b))")
        } else {
            check("背景色自动检测", false, "未检测到背景色")
        }

        // --- multi-curve extraction ----------------------------------------
        // A journal figure carries several differently coloured curves. Each has
        // to be extractable on its own: sampling one curve's colour must produce
        // a mask that contains that curve and none of the others.
        let multi = SyntheticChart.renderMulti()
        check("多曲线图生成", multi.series.count >= 3, "\(multi.series.count) 条曲线")

        var multiOK = true
        var multiDetail: [String] = []
        for (index, series) in multi.series.enumerated() {
            // The mask for this curve, with the background subtracted — the same
            // call the app makes.
            let curveMask = ForegroundMask.build(from: multi.buffer,
                                                 lineColor: series.color,
                                                 tolerance: 60,
                                                 backgroundColor: multi.backgroundColor)
            // Does it actually cover this curve? Sample ground-truth pixels.
            let hit = series.pixels.enumerated().filter { $0.offset % 37 == 0 }
                .allSatisfy { curveMask.isForeground(x: Int($0.element.x), y: Int($0.element.y)) }
            if !hit { multiOK = false; multiDetail.append("曲线\(index + 1) 未被掩膜覆盖") }

            // And does it stay off the *other* curves? This is the failure a
            // one-sided colour test produces: neighbouring curves leak in.
            for (otherIndex, other) in multi.series.enumerated() where otherIndex != index {
                let leaked = other.pixels.enumerated().filter { $0.offset % 37 == 0 }
                    .filter { curveMask.isForeground(x: Int($0.element.x), y: Int($0.element.y)) }
                    .count
                if leaked > 0 {
                    multiOK = false
                    multiDetail.append("曲线\(index + 1) 的掩膜混入了曲线\(otherIndex + 1)(\(leaked) 个像素)")
                }
            }
        }
        check("每条曲线的掩膜互不混入", multiOK,
              multiDetail.isEmpty ? "3 条曲线各自独立" : multiDetail.joined(separator: "; "))

        // A *pale* curve is where the one-sided colour test actually fails: its
        // colour is close enough to the white background that a tolerance wide
        // enough to capture the stroke captures the whole plot as well. This is
        // the acceptance criterion for the background term in the mask — the
        // property that makes extracting a curve one click instead of a
        // painstaking tolerance hunt.
        let paleColor = RGB8(r: 200, g: 205, b: 215)
        let pale = SyntheticChart.renderMulti(
            functions: [
                { 1.0 + 0.5 * sin(0.5 * $0 + 0.3) },
                { 4.0 + 0.4 * sin(0.5 * $0 + 2.0) },
            ],
            colors: [paleColor, RGB8(r: 210, g: 40, b: 40)])
        let paleCurve = pale.series[0]

        let withoutBackground = ForegroundMask.build(from: pale.buffer,
                                                     lineColor: paleColor,
                                                     tolerance: 60)
        let withBackground = ForegroundMask.build(from: pale.buffer,
                                                  lineColor: paleColor,
                                                  tolerance: 60,
                                                  backgroundColor: pale.backgroundColor)
        let plainCount = withoutBackground.bits.filter { $0 }.count
        let backgroundAwareCount = withBackground.bits.filter { $0 }.count
        let total = pale.buffer.width * pale.buffer.height
        check("浅色曲线:仅靠颜色会把整个背景判为前景",
              plainCount > total / 2,
              "\(plainCount) / \(total) 个像素(占 \(plainCount * 100 / total)%)")
        check("浅色曲线:扣除背景后只剩曲线本身",
              backgroundAwareCount < total / 20 && backgroundAwareCount > 500,
              "\(backgroundAwareCount) 个像素")
        // And the stroke must still be fully covered — removing the background
        // is worthless if it removes the curve too.
        let paleCovered = paleCurve.pixels.enumerated().filter { $0.offset % 37 == 0 }
            .allSatisfy { withBackground.isForeground(x: Int($0.element.x),
                                                      y: Int($0.element.y)) }
        check("浅色曲线仍被完整覆盖", paleCovered)

        // The reported bug, at the colours and spacing of the figure it came
        // with: green (103,186,103) against orange (255,164,84). The two hues are
        // 89° apart — unmistakable to the eye — but only **59.7** apart under the
        // mask's weighted metric, inside the default tolerance of 60, while the
        // orange stroke is 115.9 from the white page. Both older gates therefore
        // say yes to the whole neighbouring curve, and area digitising reported
        // points sitting on it.
        //
        // The chart has to be softened first. `SyntheticChart` draws hard-edged
        // discs, so not one pixel of its orange stroke is "orange blended with
        // white" — and that anti-aliased rim is the entire leak. The `leaked > 0`
        // half of the assertion is what keeps this honest: if the fixture ever
        // stops reproducing the bug, the check fails instead of passing quietly.
        let report = SyntheticChart.renderMulti(
            size: (width: 900, height: 640),
            functions: [{ 1.0 + 0.5 * sin(0.5 * $0 + 0.3) },
                        { 4.0 + 0.4 * sin(0.5 * $0 + 2.0) }],
            colors: [RGB8(r: 103, g: 186, b: 103), RGB8(r: 255, g: 164, b: 84)],
            lineWidth: 9)
        let reportBuffer = softened(report.buffer)
        let reportRect = PixelRect(x0: 81, y0: 41, x1: 858, y1: 578)

        func reportPoints(hueTolerance: Double) -> [PixelPoint] {
            let mask = ForegroundMask.build(from: reportBuffer,
                                            lineColor: report.series[0].color,
                                            tolerance: 60,
                                            backgroundColor: report.backgroundColor,
                                            hueTolerance: hueTolerance)
            return AreaDigitizer.digitize(mask: mask, rect: reportRect, dx: 18)
        }
        /// How many of `points` land on the *other* curve, which is the symptom
        /// the user reported.
        func pointsOnTheOrangeCurve(_ points: [PixelPoint]) -> Int {
            points.filter { p in
                guard let near = report.series[1].pixels
                    .min(by: { abs($0.x - p.x) < abs($1.x - p.x) }) else { return false }
                return abs(near.y - p.y) <= 4
            }.count
        }
        let leaked = pointsOnTheOrangeCurve(reportPoints(hueTolerance: 180))
        let kept = pointsOnTheOrangeCurve(reportPoints(hueTolerance: ForegroundMask.defaultHueTolerance))
        check("区域取点不会读到另一条同亮度的曲线(报告同款绿/橙)",
              leaked > 0 && kept == 0,
              "关掉色相闸门 \(leaked) 个点落在橙曲线上,打开后 \(kept) 个")

        // Extracting each curve in turn must give each one its own points.
        var multiState = ProjectState(calibration: multi.calibration)
        multiState.defaultBackgroundColor = multi.backgroundColor
        var perCurveCounts: [Int] = []
        for series in multi.series {
            let id = multiState.addLine(color: series.color)
            multiState.setLineColor(series.color, for: id)
            let mask = ForegroundMask.build(from: multi.buffer,
                                            lineColor: series.color,
                                            tolerance: 60,
                                            backgroundColor: multi.backgroundColor)
            let rect = PixelRect(x0: multi.axisX0 + 2, y0: multi.axisY1,
                                 x1: multi.axisX1, y1: multi.axisY0 - 2)
            let extracted = AreaDigitizer.digitize(mask: mask, rect: rect, dx: 8)
            multiState.replacePoints(of: id, with: extracted)
            perCurveCounts.append(extracted.count)
        }
        check("多曲线各自取点", perCurveCounts.allSatisfy { $0 > 40 },
              perCurveCounts.map(String.init).joined(separator: " / "))

        // Every curve's data must be right — checked against its own function,
        // not just non-empty.
        var perCurveAccurate = true
        for (index, series) in multi.series.enumerated() {
            guard index < multiState.lines.count,
                  case let points = multiState.lines[index].points, !points.isEmpty else {
                perCurveAccurate = false; break
            }
            let errors = multiYErrors(points, truth: series.pixels, map: multi.calibration)
            let p95 = percentile(errors, 95)
            if !(p95 <= 0.01) { perCurveAccurate = false }
        }
        check("多曲线精度 p95 ≤ 1%", perCurveAccurate)

        // The exported file must be a table a parser can read: three curves is
        // **one wide table**, not three named blocks. The layout changed on
        // purpose — `#` is not part of CSV, so pandas rejects the file and Excel
        // puts the names in column A as data, both silently.
        do {
            let csv = try Exporter.text(for: multiState.lines,
                                        calibration: multi.calibration, format: .csv)
            let rows = csv.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.split(separator: ",", omittingEmptySubsequences: false) }
            let width = multiState.lines.count * 2
            let header = csv.split(separator: "\n").first.map(String.init) ?? ""
            let wantHeader = (1...multiState.lines.count).flatMap { ["x\($0)", "y\($0)"] }
                .joined(separator: ",")
            // The trailing empty string is the newline at the end of the body, and
            // splitting it gives no cells at all — so it is dropped, not counted.
            let body = rows.dropLast()
            let sameWidth = !body.isEmpty && body.allSatisfy { $0.count == width }
            let noComments = !csv.contains("# ")
            let ok = header == wantHeader && sameWidth && noComments
            check("多条曲线导出成一张可解析的宽表(表头 x1,y1,…)", ok,
                  ok ? "\(multiState.lines.count) 条曲线 · 每行 \(width) 列 · 无注释行"
                     : "表头=\(header)(应为 \(wantHeader)) 等宽=\(sameWidth) 无注释=\(noComments)")
        } catch {
            check("多条曲线导出成一张可解析的宽表(表头 x1,y1,…)", false, "抛出 \(error)")
        }

        // --- point order -----------------------------------------------------
        // Order is not cosmetic: consecutive points define the polyline.
        let shuffled = [PixelPoint(x: 300, y: 10), PixelPoint(x: 100, y: 30),
                        PixelPoint(x: 200, y: 20), PixelPoint(x: 200, y: 25)]
        let ascending = PointOrder.ascendingX.apply(to: shuffled)
        check("X 升序排列正确",
              ascending.map(\.x) == [100, 200, 200, 300],
              ascending.map { Int($0.x) }.description)
        // Stability: the two points sharing x=200 keep their original relative
        // order, so a vertical run is not reversed arbitrarily. Note this check
        // pins the intent rather than detecting a regression — Swift's `sorted`
        // makes no stability promise but is in fact stable at every size tried,
        // so dropping the tie-break does not fail here. The tie-break stays in
        // `PointOrder` because the promise is what the code should not rely on.
        check("同 X 的点保持原相对顺序",
              ascending[1].y == 20 && ascending[2].y == 25)
        check("反转顺序", PointOrder.reversed.apply(to: shuffled).first?.x == 200)
        check("取点顺序不改动", PointOrder.extraction.apply(to: shuffled).map(\.x) == [300, 100, 200, 200])

        // The diagnosis is what warns the user; it must actually fire — and it
        // must distinguish a genuine fold-back from a curve simply taken right
        // to left, which is monotonic and perfectly fine.
        let backwards = [PixelPoint(x: 300, y: 0), PixelPoint(x: 200, y: 1), PixelPoint(x: 100, y: 2)]
        let forward = [PixelPoint(x: 100, y: 0), PixelPoint(x: 200, y: 1), PixelPoint(x: 300, y: 2)]
        let folded = [PixelPoint(x: 100, y: 0), PixelPoint(x: 300, y: 1),
                      PixelPoint(x: 150, y: 2), PixelPoint(x: 250, y: 3)]
        check("右向左取点不算折返",
              OrderDiagnosis(points: backwards).isMonotonicInX
              && OrderDiagnosis(points: backwards).reversals == 0)
        // 100 -> 300 -> 150 -> 250 turns twice: right, left, right.
        check("真正的折返能诊断出来",
              !OrderDiagnosis(points: folded).isMonotonicInX
              && OrderDiagnosis(points: folded).reversals == 2,
              "\(OrderDiagnosis(points: folded).reversals) 次方向变化")
        check("顺序正确时不误报", OrderDiagnosis(points: forward).isMonotonicInX)

        // A line's order setting must reach the exported polyline, which is the
        // only reason the setting exists.
        var orderState = ProjectState(calibration: chart.calibration)
        let orderLine = orderState.addLine(color: chart.lineColor)
        orderState.replacePoints(of: orderLine, with: backwards)
        let extractionExport = try? Exporter.text(for: orderState.lines,
                                                  calibration: chart.calibration,
                                                  format: .csv, includeHeader: false)
        orderState.setOrder(.ascendingX, for: orderLine)
        let ascendingExport = try? Exporter.text(for: orderState.lines,
                                                 calibration: chart.calibration,
                                                 format: .csv, includeHeader: false)
        let extractedFirstX = extractionExport?.split(separator: "\n").first
            .flatMap { Double($0.split(separator: ",")[0]) } ?? .nan
        let sortedFirstX = ascendingExport?.split(separator: "\n").first
            .flatMap { Double($0.split(separator: ",")[0]) } ?? .nan
        check("取点顺序会改变导出结果",
              extractedFirstX > sortedFirstX,
              String(format: "%.3f -> %.3f", extractedFirstX, sortedFirstX))

        // --- what the canvas actually draws ---------------------------------
        // The three things the user asked to see: a marker distinguishable from
        // a curve of its own colour, a polyline that follows the order setting,
        // and several curves each drawn in its own colour. All three are
        // properties of the rendered pixels, so they are measured off the real
        // view's cached display rather than asserted about the model.
        check("画布上点的标记有白色描边(不与曲线融为一团)", markerHaloIsVisible())
        check("点顺序会改变画布上的连线", orderChangesTheLineDrawn())
        check("多条曲线各自用自己的颜色绘制", eachCurveKeepsItsOwnColour())

        // --- eraser and re-digitise ------------------------------------------
        // The two tools the request asked for, driven through real mouse events
        // and the same circles and rectangles the tools draw.
        let eraser = eraserRemovesExactlyTheRing()
        check("橡皮擦只删掉圆圈碰到的点", eraser.passed, eraser.detail)
        let scaled = eraserRingFollowsZoom()
        check("橡皮擦圆圈按缩放换算到图像", scaled.passed, scaled.detail)
        check("橡皮擦拖拽可连续擦除", eraserDragErasesAlongThePath())
        let clamp = eraserRadiusClampsWithoutRecursing()
        check("橡皮擦半径在 6–120 之间夹紧", clamp.passed, clamp.detail)

        let redigit = redigitizeReplacesTheRegion()
        check("重新选点清空区间后重取该段(框外不动)", redigit.passed, redigit.detail)
        check("重新选点点击时删除最近的一个点", redigitizeClickRemovesNearest())

        // --- 撤销 / 恢复 ------------------------------------------------------
        // The stack's own bookkeeping is unit-tested in `UndoHistoryTests`. What
        // these cover is the part a unit test cannot reach: that the canvas
        // records the actions at all, that a drag is *one* action rather than one
        // per mouse-moved, that an undo puts the masks back in step with the
        // state it restored, and that 恢复 hands the same state back.
        let historyControl = historyControlFollowsTheHistory()
        check("工具栏的撤销/恢复各自随历史启用", historyControl.passed, historyControl.detail)
        let historyWiring = historySegmentsFireTheirOwnActions()
        check("工具栏的撤销/恢复段各连各的动作", historyWiring.passed, historyWiring.detail)
        let undoneErase = undoBringsBackAnErasedStroke()
        check("撤销能把擦掉的一整笔点找回来", undoneErase.passed, undoneErase.detail)
        let redoneErase = redoPutsBackWhatUndoTookAway()
        check("恢复能把撤销掉的一整笔点还回来", redoneErase.passed, redoneErase.detail)
        let oneStroke = oneDragIsOneUndoStep()
        check("一次拖拽只记一步撤销", oneStroke.passed, oneStroke.detail)
        let undonePass = undoTakesBackAPointTakingPass()
        check("撤销能把一次取点整体撤回", undonePass.passed, undonePass.detail)
        let maskFollows = undoKeepsTheMaskInStepWithTheColour()
        check("撤销取色时掩膜一并退回(重做再回来)", maskFollows.passed, maskFollows.detail)
        let historyCleared = loadingAnImageForgetsTheHistory()
        check("换一张图会清空撤销历史", historyCleared.passed, historyCleared.detail)

        // --- 项目文件:保存 / 打开 --------------------------------------------
        // The container's own encoding — the prologue, the offsets, which failure
        // is which — is unit-tested in `ProjectFileTests`, where a made-up state
        // makes every field easy to name. What is left for the selftest is what a
        // unit test cannot reach: that a *session* built through the real canvas
        // paths survives a real file and a real reopen, that the curve that comes
        // back is immediately usable rather than merely present, and that the
        // 「未保存」 mark follows the file rather than the keyboard.
        let roundTrip = projectSurvivesAFileRoundTrip()
        check("项目存盘再打开,标定/锚点/曲线/点位逐项一致", roundTrip.passed, roundTrip.detail)
        let byteExact = projectKeepsTheOriginalImageBytes()
        check("项目存的是原图字节,再打开后像素完全一致", byteExact.passed, byteExact.detail)
        let reopenUsable = reopenedProjectIsReadyForMorePoints()
        check("打开项目后曲线可直接继续取点(掩膜已重建)", reopenUsable.passed, reopenUsable.detail)
        let reopenClean = openingAProjectForgetsTheHistory()
        check("打开项目会清空撤销历史", reopenClean.passed, reopenClean.detail)
        let refuses = brokenProjectFilesAreRefused()
        check("坏文件被逐类拒绝,且分别给出可读说明", refuses.passed, refuses.detail)
        let unsavedMark = theUnsavedMarkFollowsTheFile()
        check("未保存标记随编辑出现、保存后消失、撤销回干净", unsavedMark.passed, unsavedMark.detail)
        let menu = theMenuBarKeepsItsPromises()
        check("菜单快捷键无冲突,⌘S/⌘O 归保存与打开", menu.passed, menu.detail)
        let replaceGuard = openingAFileAsksBeforeDiscardingTheDocument()
        check("打开别的文件会先问,取消后原文档逐项保留、不保存才换", replaceGuard.passed, replaceGuard.detail)

        // --- 导出格式 (FR-9 / FR-11)------------------------------------------
        let separator = theDecimalSeparatorReachesTheExportedBytes()
        check("导出小数分隔符真的进了文件:逗号时 1,875000 且 CSV 列改用分号,默认仍是句点",
              separator.passed, separator.detail)

        // --- 多坐标系 (FR-13)-----------------------------------------------
        let systems = twoCoordinateSystemsConvertTheirOwnCurves()
        check("同一张图两套坐标系:每条曲线按自己那套换算,选中曲线即切换,挂曲线的删不掉",
              systems.passed, systems.detail)
        let armsCalibration = addingASystemArmsCalibration()
        check("新增坐标系后自动切到「标定坐标系」(取点中也不例外)",
              armsCalibration.passed, armsCalibration.detail)

        // --- 两个「用来看」的视图(FR-1.3 / FR-7.1)-----------------------------
        let hideImage = hidingTheImageTakesNothingAway()
        check("隐藏原图只是不画它:文档不变、位图与掩膜都在,且仍能取点", hideImage.passed, hideImage.detail)
        let dataView = theDataViewShowsAnOrderTheCanvasCannot()
        check("同一批点在数据坐标里,列序折线明显长于行序(取歪看得出来)", dataView.passed, dataView.detail)
        let labels = theDataPlotLabelsAreReadable()
        check("数据视图刻度标签是圆整数,不会出现 0.6000000000000001", labels.passed, labels.detail)

        // --- 点编辑与数据表 (FR-6.4 / FR-7.2)--------------------------------
        let move = pointEditingMovesExactlyOneMarker()
        check("点编辑:拖动只动那一个点,其余原样,一次手势记一步撤销", move.passed, move.detail)
        let insert = pointEditingInsertsOnTheLineThenDeletes()
        check("点编辑:在连线上点一下插入,新点落在该段两端之间,⌫ 删掉它", insert.passed, insert.detail)
        let orderFree = pointEditingWritesTheDisplayedMarkerNotTheStoredIndex()
        check("反转顺序下拖第一个标记,动的是存储里的最后一个点", orderFree.passed, orderFree.detail)
        let table = thePointTableEditsTheDisplayedPoint()
        check("数据表改的是显示序那一行的点,只改被改的那一轴,非法输入被拒", table.passed, table.detail)

        // --- 符号匹配(散点图)------------------------------------------------
        let symbols = symbolMatchingTakesEverySymbol()
        check("符号匹配:一次取出全部散点符号,预览随工具/直径刷新,一次撤销即可回退", symbols.passed, symbols.detail)
        let legend = symbolMatchingLeavesTheLegendAlone()
        check("同色图例色块不会被当成数据点", legend.passed, legend.detail)

        // --- 点重排 -----------------------------------------------------------
        // Same ring, same conversion as the eraser; what is different is that the
        // result is an *order*, so the checks are about what the brush's path
        // implies rather than about which points survived.
        let reorderSweep = reorderSweepFollowsTheBrushPath()
        check("点重排按圈刷扫过的先后重新编号", reorderSweep.passed, reorderSweep.detail)
        let reorderZoom = reorderRingFollowsZoom()
        check("点重排圈按缩放换算到图像", reorderZoom.passed, reorderZoom.detail)

        // The strip's right end carries the active tool's own number. At the
        // narrowest width the window can take, the control must still sit clear
        // of the status text rather than painting over it — and it must show the
        // parameter its own tool works by.
        let parameterBar = infoBarControlFitsAtMinimumWidth()
        check("状态条参数控件不与状态文字重叠(隐藏时交还宽度)", parameterBar.passed, parameterBar.detail)
        let parameterSlider = parameterSliderDrivesTheCanvas()
        check("状态条滑槽范围与画布一致,且能驱动半径与间距", parameterSlider.passed, parameterSlider.detail)
        let parameterScope = parameterControlFollowsTheTool()
        check("参数控件随工具切换(半径/间距/不出现)", parameterScope.passed, parameterScope.detail)
        let spacingDefaults = spacingDefaultsMatchTheModel()
        check("间距默认值与 GDCore 的初值一致", spacingDefaults.passed, spacingDefaults.detail)

        // --- 取点密度 ---------------------------------------------------------
        // The two spacings are the tools' own numbers, so they are checked where
        // they act: how many points the scan and the walk actually produce.
        // Asserting the stored value would pass for a control wired to nothing.
        let gridDensity = gridSpacingDecidesThePointCount()
        check("网格间距决定区域取点的点数(粗 ⊂ 细)", gridDensity.passed, gridDensity.detail)
        let traceDensity = traceSpacingThinsTheTracedCurve()
        check("取点密度只抽稀自动跟踪的点,不改路线", traceDensity.passed, traceDensity.detail)

        // --- 网格方向与偏移(FR-5.4 / FR-5.5)--------------------------------
        // The sweeps themselves are unit-tested against hand-built masks in
        // `DigitizerTests`. What is left for here is the wiring: that the menu's
        // direction reaches the digitizer at all, and that aligning the grid
        // moves the lines to the pixel it was asked for — both asserted on the
        // coordinates that come back, not on the setting that was stored, because
        // a setting that changed nothing on screen would pass the latter.
        let gridDirection = gridAxisReachesTheDigitizer()
        check("网格方向真的是换了一套扫描(落格坐标随之换轴)", gridDirection.passed, gridDirection.detail)
        let gridAlignment = aligningTheGridPutsTheLinesOnTheAnchor()
        check("网格对齐到坐标轴起点后,扫描线穿过该列", gridAlignment.passed, gridAlignment.detail)

        // --- sidebar ---------------------------------------------------------
        // The panel is where the live coordinates are read, so it has to hold
        // every curve and every point without confusing the two tables.
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 264, height: 700))
        sidebar.update(lines: multiState.lines,
                       calibration: multi.calibration,
                       activeID: multiState.lines.first?.id)
        sidebar.layoutSubtreeIfNeeded()
        // The table of coordinates must be a scrolling view, or a traced curve
        // of thousands of points would be unreadable past the first screenful.
        // Each table sits inside a card, so walk the whole subtree rather than
        // only the panel's direct subviews.
        let scrolls = descendants(of: sidebar).compactMap { $0 as? NSScrollView }
            .filter { $0.hasVerticalScroller }
        check("坐标面板有可滚动的数据区", scrolls.count >= 2, "\(scrolls.count) 个滚动区")

        // The panel holds two tables, and the whole point of the design is that
        // they show different things: every curve above, and the active curve's
        // points below. Wiring them the wrong way round would still scroll and
        // still look plausible, so the row counts are checked directly.
        // Which table is which cannot be told from the row counts — the curve
        // list may well be the shorter of the two. Identify them by shape: the
        // curve list has a single unnamed column, the point table the three
        // columns #, X, Y.
        let sidebarTables = scrolls.compactMap { $0.documentView as? NSTableView }
        let curveTable = sidebarTables.first { $0.numberOfColumns == 1 }
        let pointTable = sidebarTables.first {
            $0.tableColumns.map(\.identifier.rawValue) == ["index", "x", "y"]
        }
        let curveRows = curveTable?.numberOfRows ?? -1
        let pointRows = pointTable?.numberOfRows ?? -1
        let activePointCount = multiState.lines.first?.points.count ?? -1
        check("面板上方列全部曲线、下方列当前曲线的点",
              curveRows == multiState.lines.count && pointRows == activePointCount,
              "曲线 \(curveRows)/\(multiState.lines.count), 点 \(pointRows)/\(activePointCount)")

        // Switching the active curve must switch the point table with it.
        if multiState.lines.count >= 2 {
            let second = multiState.lines[1]
            sidebar.update(lines: multiState.lines,
                           calibration: multi.calibration,
                           activeID: second.id)
            sidebar.layoutSubtreeIfNeeded()
            let afterSwitch = pointTable?.numberOfRows ?? -1
            let curveRowsAfter = curveTable?.numberOfRows ?? -1
            check("切换曲线后坐标区跟着切换",
                  afterSwitch == second.points.count
                    && curveRowsAfter == multiState.lines.count,
                  "点表 \(afterSwitch) 行/应为 \(second.points.count),"
                    + " 曲线表仍 \(curveRowsAfter) 行")
        }

        // The coordinates shown must be the calibrated values, not raw pixels —
        // this is the readout the whole panel exists for.
        // The values shown must be the chart's values, not pixel coordinates: a
        // point 82 px into a 780 px axis spanning 0…10 has to read about 0.03,
        // and its row has to land inside the 0…5 value range. Checking the
        // numbers against the calibration rather than against a ground-truth
        // point keeps this honest when the extraction grid shifts.
        if let line = multiState.lines.first, let pixel = line.orderedPoints.first,
           let data = try? multi.calibration.data(fromPixel: pixel) {
            let looksCalibrated = abs(data.x) < 100 && abs(data.y) < 100
                && data.x != pixel.x && data.y != pixel.y
            let independentlyChecked = (try? multi.calibration.data(
                fromPixel: PixelPoint(x: Double(multi.axisX0), y: Double(multi.axisY0)))) == nil
                ? false
                : true
            let originValue = try? multi.calibration.data(
                fromPixel: PixelPoint(x: Double(multi.axisX0), y: Double(multi.axisY0)))
            let nearOrigin = abs((originValue?.x ?? 99)) < 0.01 && abs((originValue?.y ?? 99)) < 0.01
            check("坐标面板显示的是标定后的数值",
                  looksCalibrated && independentlyChecked && nearOrigin,
                  String(format: "首点 (%.4f, %.4f), 轴原点应读 (0, 0)", data.x, data.y))
        } else {
            check("坐标面板显示的是标定后的数值", false, "无取到的点")
        }

        // --- layout with the panel -------------------------------------------
        let panelContainer = NSView(frame: NSRect(x: 0, y: 0, width: 1_400, height: 840))
        let panelToolbar = NSView(frame: .zero)
        let panelInfo = NSView(frame: .zero)
        let panelCanvas = NSView(frame: .zero)
        let panelSidebar = NSView(frame: .zero)
        MainLayout.install(container: panelContainer, toolbar: panelToolbar,
                           canvas: panelCanvas, sidebar: panelSidebar,
                           infoBar: panelInfo)
        var panelOK = true
        var panelDetail = ""
        for size in [(1_200.0, 840.0), (1_400.0, 1_440.0), (1_600.0, 700.0)] {
            panelContainer.frame = NSRect(x: 0, y: 0, width: size.0, height: size.1)
            panelContainer.layoutSubtreeIfNeeded()
            let sideWideEnough = abs(panelSidebar.frame.width - MainLayout.sidebarWidth) < 0.5
            let sideFlushRight = abs(panelSidebar.frame.maxX - size.0) < 0.5
            let canvasClears = panelCanvas.frame.maxX <= panelSidebar.frame.minX + 0.5
            let noOverlap = !panelCanvas.frame.intersects(panelSidebar.frame)
            let canvasNonEmpty = panelCanvas.frame.width > 200
            if !(sideWideEnough && sideFlushRight && canvasClears && noOverlap && canvasNonEmpty) {
                panelOK = false
                panelDetail = "尺寸 \(Int(size.0))x\(Int(size.1)): 面板宽 \(Int(panelSidebar.frame.width)), "
                    + "画布宽 \(Int(panelCanvas.frame.width)), 重叠 \(noOverlap ? "否" : "是")"
                break
            }
        }
        check("数据面板与画布不重叠", panelOK, panelDetail)

        // The window is a stack of full-width bands, and the panel is the one
        // column that runs beside them. A gap between two bands, or a band that
        // stops short of the panel, is the dead-looking stripe the user pointed
        // at — so the geometry is asserted rather than eyeballed.
        panelContainer.frame = NSRect(x: 0, y: 0, width: 1_400, height: 840)
        panelContainer.layoutSubtreeIfNeeded()
        // Container coordinates are bottom-up: the toolbar is the topmost band,
        // so it has the largest maxY.
        let bands = [panelToolbar, panelInfo, panelCanvas]
        let stackTop = bands.map(\.frame.maxY).max() ?? 0
        let stackBottom = bands.map(\.frame.minY).min() ?? 0
        let stackFlushTop = abs(stackTop - panelContainer.bounds.maxY) < 0.5
        let stackFlushBottom = abs(stackBottom - panelContainer.bounds.minY) < 0.5
        let bandsMeet = abs(panelToolbar.frame.minY - panelInfo.frame.maxY) < 0.5
            && abs(panelInfo.frame.minY - panelCanvas.frame.maxY) < 0.5
        let bandColumnsMatch = abs(panelToolbar.frame.minX - panelContainer.bounds.minX) < 0.5
            && abs(panelInfo.frame.minX - panelContainer.bounds.minX) < 0.5
            && abs(panelToolbar.frame.maxX - panelSidebar.frame.minX) < 0.5
            && abs(panelInfo.frame.maxX - panelSidebar.frame.minX) < 0.5
        check("工具栏/状态条/画布三段上下相接且与面板同宽",
              stackFlushTop && stackFlushBottom && bandsMeet && bandColumnsMatch,
              "工具条 \(Int(panelToolbar.frame.minY))–\(Int(panelToolbar.frame.maxY)), "
                + "状态条 \(Int(panelInfo.frame.minY))–\(Int(panelInfo.frame.maxY)), "
                + "画布 \(Int(panelCanvas.frame.minY))–\(Int(panelCanvas.frame.maxY)), "
                + "面板 x \(Int(panelSidebar.frame.minX))–\(Int(panelSidebar.frame.maxX))")

        // The panel owns its full column, so its top edge coincides with the
        // toolbar's. Starting it below the toolbar left a stub of window
        // background at the top right — the empty corner the user circled.
        let sidebarTopsOut = abs(panelSidebar.frame.maxY - panelContainer.bounds.maxY) < 0.5
            && abs(panelSidebar.frame.minY - panelContainer.bounds.minY) < 0.5
        check("数据面板占满整列高度(顶部与工具栏齐平)", sidebarTopsOut,
              "面板 \(Int(panelSidebar.frame.minY))–\(Int(panelSidebar.frame.maxY))"
                + " / 窗口 \(Int(panelContainer.bounds.minY))–\(Int(panelContainer.bounds.maxY))")

        check("面板三段自上而下排满,没有空档", sidebarBandsAreTight())
        check("数据表画出 Excel 式的行列网格", pointTableDrawsGrid())

        // --- calibration validation ------------------------------------------
        // A log axis has no zero, so both of its values have to be positive. The
        // sheet used to reject it with "不是正数" and nothing else, which told
        // the user what was wrong but not what to type; these checks pin the
        // wording to a number they can actually use.
        let splitAnchors = CalibrationAnchors(xStart: PixelPoint(x: 20, y: 300),
                                              xEnd: PixelPoint(x: 500, y: 300),
                                              yStart: PixelPoint(x: 20, y: 300),
                                              yEnd: PixelPoint(x: 20, y: 20))
        let logMessage = CalibrationSheet.validate(
            anchors: splitAnchors,
            xStart: 0, xEnd: 100, yStart: 1, yEnd: 10,
            xIsLog: true, yIsLog: false)
        check("log 轴起始为 0 时给出可照抄的正值",
              logMessage?.contains("必须为正数") == true
                && logMessage?.contains("对数轴没有 0") == true
                && logMessage?.contains("例如 1。") == true,
              logMessage ?? "没有报错")

        let mismatch = CalibrationSheet.validate(
            anchors: splitAnchors,
            xStart: 5, xEnd: 5, yStart: 1, yEnd: 10,
            xIsLog: false, yIsLog: false)
        check("起止值相同会被拦下", mismatch?.contains("不能相同") == true,
              mismatch ?? "没有报错")

        let collinear = CalibrationSheet.validate(
            anchors: CalibrationAnchors(xStart: PixelPoint(x: 20, y: 300),
                                        xEnd: PixelPoint(x: 20.4, y: 50),
                                        yStart: PixelPoint(x: 20, y: 300),
                                        yEnd: PixelPoint(x: 20, y: 20)),
            xStart: 0, xEnd: 10, yStart: 0, yEnd: 10,
            xIsLog: false, yIsLog: false)
        check("X 轴两点几乎同列会被拦下", collinear?.contains("横轴的两端") == true,
              collinear ?? "没有报错")

        check("合法的标定数值不报错", CalibrationSheet.validate(
            anchors: splitAnchors,
            xStart: 0, xEnd: 10, yStart: 0, yEnd: 10,
            xIsLog: false, yIsLog: false) == nil)

        check("对数轴起点的建议值小于末端值", [(100.0, 1.0), (1_000.0, 1.0), (10.0, 1.0), (5.0, 1.0)]
            .allSatisfy { CalibrationSheet.logStartDefault(below: $0.0) == $0.1
                && $0.1 < $0.0 })
        check("末端值不超过 1 的对数轴按十倍递减",
              CalibrationSheet.logStartDefault(below: 1) == 0.1
                && CalibrationSheet.logStartDefault(below: 0.5) == 0.1
                && CalibrationSheet.logStartDefault(below: 0.05) == 0.01
                && CalibrationSheet.logStartDefault(below: 0) == 1)

        // Ticking log on a sheet that was left at the default start must repair
        // the number rather than pop an error the moment OK is pressed.
        check("勾上 log 会自动把非正的起止值改成正值",
              CalibrationSheet.logStartRepair(current: 0, axisEnd: 100) == "1"
                && CalibrationSheet.logStartRepair(current: -3, axisEnd: 1_000) == "1"
                && CalibrationSheet.logEndRepair(current: 0, axisStart: 1) == "10",
              "0→\(CalibrationSheet.logStartRepair(current: 0, axisEnd: 100) ?? "nil"), "
                + "-3→\(CalibrationSheet.logStartRepair(current: -3, axisEnd: 1_000) ?? "nil")")

        check("已经是正值的起止值不会被改动",
              CalibrationSheet.logStartRepair(current: 0.5, axisEnd: 100) == nil
                && CalibrationSheet.logStartRepair(current: 2, axisEnd: 100) == nil
                && CalibrationSheet.logEndRepair(current: 100, axisStart: 1) == nil)

        // Starting a second calibration over an existing one must be refused
        // unless the caller has asked the user first. The canvas owns that rule;
        // this drives it directly, so removing the guard cannot pass unnoticed.
        let guardProbe = beginCalibrationRefusal()
        check("已标定时拒绝静默重标", guardProbe.passed, guardProbe.detail)
        check("没有锚点的标定仍能定位四个标记", calibrationFallbackAnchorsAreUsable())
        let editProbe = editingValuesKeepsTheMarkers()
        check("修改标定数值不移动四个标记", editProbe.passed, editProbe.detail)
        let formProbe = calibrationFormColumnsDoNotOverlap()
        check("标定表单的名字/像素/输入三列不重叠", formProbe.passed, formProbe.detail)
        let promptProbe = calibrationPromptAdvancesWithEachClick()
        check("标定每点一下步骤提示就前进一格", promptProbe.passed, promptProbe.detail)

        // The handles are editing affordances, not part of the chart. Both these
        // are read off rendered frames, because the model is identical either way:
        // every model-level assertion above passes with four discs sitting on top
        // of the data.
        let handleProbe = calibrationHandlesStayOutOfTheWay()
        check("标定标记默认不画、鼠标靠近才出现", handleProbe.passed, handleProbe.detail)
        let pillProbe = calibrationHandleLabelsDropThePixelReadout()
        check("标定标记的标签不再带像素坐标", pillProbe.passed, pillProbe.detail)

        // Ticks ride their own rule. With four anchors the two axes' cross-axis
        // coordinates are independent, so a tick's row comes from interpolating
        // along the X rule rather than from any single anchor's row — the check
        // that fails if a tick is placed at one anchor's coordinate instead.
        let tickProbe = ticksFollowTheirOwnRule()
        check("刻度沿所在轴规则插值(不再取单点坐标)", tickProbe.passed, tickProbe.detail)

        // And the overlay actually paints that way. The arithmetic above is the
        // rule; this is the pixels — a regression that kept the interpolation
        // but drew the rule from a shared corner would pass the one and fail
        // this.
        let painted = calibrationRulesPaintWhereTheyWereClicked()
        check("两根轴规则画在各自锚点上(不再共用角点)", painted.passed, painted.detail)

        // --- panel selection is not re-entrant --------------------------------
        // Selecting a curve in the panel posts a selection notification, and the
        // delegate answers it by selecting that curve on the canvas, which
        // refreshes the panel, which re-selects the row — a loop that recursed
        // until the stack guard killed the app. This drives the real wiring with
        // a delegate that does exactly what AppDelegate does and counts the
        // round trips, so the guard cannot be removed unnoticed.
        let recursionProbe = SelectionLoopProbe()
        let probePanel = SidebarView(frame: NSRect(x: 0, y: 0, width: 264, height: 700))
        recursionProbe.panel = probePanel
        probePanel.delegate = recursionProbe
        var probeLines: [CurveLine] = []
        for index in 0..<3 {
            var line = CurveLine(name: "曲线 \(index + 1)", color: RGB8(r: 200, g: 40, b: 90))
            line.lineColor = RGB8(r: 200, g: 40, b: 90)
            for x in 0..<8 { line.points.append(PixelPoint(x: Double(x) * 5, y: Double(x) * 3)) }
            probeLines.append(line)
        }
        recursionProbe.lines = probeLines
        probePanel.update(lines: probeLines, calibration: nil, activeID: probeLines[0].id)
        probePanel.update(lines: probeLines, calibration: nil, activeID: probeLines[1].id)
        probePanel.update(lines: probeLines, calibration: nil, activeID: probeLines[2].id)
        check("面板选中曲线不会自我递归", recursionProbe.roundTrips <= 3,
              "\(recursionProbe.roundTrips) 次回环")

        // The window minimum must fit the toolbar row *and* the panel side by
        // side, because the toolbar shares the canvas column. This builds the
        // row at exactly the width the real window would give it and measures
        // the buttons, rather than trusting a formula: the previous version
        // compared `minimumWindowWidth + sidebarWidth` against the toolbar, so
        // it agreed with the bug that clipped the right-hand buttons.
        //
        // The band is 40pt narrower the second time round, and the row's own
        // claim on the width is required to hold in both. That is the failure
        // mode the window minimum protects against — the window reserving less
        // than the row needs — and it stays caught if the row's arithmetic and
        // `requiredWidth` start to drift apart.
        let minWindow = MainLayout.windowMinimumWidth(toolbarWidth: toolbar.requiredWidth)
        let minBand = minWindow - MainLayout.sidebarWidth
        var problems: [String] = []
        var rowWidth = CGFloat(0)
        for slack in [CGFloat(0), -40] {
            let bandWidth = minBand + slack
            let row = ToolbarView(frame: NSRect(x: 0, y: 0, width: bandWidth,
                                                height: MainLayout.toolbarHeight))
            rowWidth = max(rowWidth, row.requiredWidth)
            // Only the real band width can be over-full; the -40 case is a
            // deliberately impossible one, asked only for the row's claim.
            if slack == 0 {
                for subview in row.subviews {
                    guard let button = subview as? NSButton, !button.title.isEmpty else { continue }
                    let needed = button.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000,
                                                                        height: button.bounds.height)).width
                    if needed > button.bounds.width + 0.5 {
                        problems.append(button.title.trimmingCharacters(in: .whitespaces))
                    }
                }
                if row.requiredWidth > bandWidth {
                    problems.append("行比可用宽度多 \(Int((row.requiredWidth - bandWidth).rounded()))pt")
                }
            }
        }
        check("最小窗口宽度下工具栏按钮仍然完整",
              problems.isEmpty && rowWidth <= minBand,
              problems.isEmpty
                ? "窗口 \(Int(minWindow)) pt = 工具栏 \(Int(rowWidth)) + 面板 \(Int(MainLayout.sidebarWidth))"
                : "被裁掉: \(problems.joined(separator: ", "))")

        // The strip the user objected to: the panel was white on white with
        // nothing to say where the work area began. Rendering is the only way to
        // catch it — a white panel and a grey one satisfy every geometric check
        // above — so the panel is painted and the pixels read back.
        let tint = sidebarPanelIsTinted()
        check("面板底色与画布区分开(不再是一片纯白)", tint.passed, tint.detail)

        let chrome = chromeFollowsAppearance()
        check("工具栏与信息条背景跟随深浅外观(不再固化在启动时的外观)",
              chrome.passed, chrome.detail)

        let listFit = curveListFitsWithoutHorizontalScrolling()
        check("曲线列表与点表不横向溢出(点数列不需要横向滚动才看得到)",
              listFit.passed, listFit.detail)

        print(String(repeating: "─", count: 62))
        if failures == 0 {
            print("全部通过。")
        } else {
            print("\(failures) 项失败。")
        }
        return failures == 0
    }

    // MARK: - Canvas rendering probes
    //
    // The three checks below are about pixels, not about the model: a marker
    // that is invisible against its own curve, an order setting that never
    // reaches the polyline, and a second curve drawn in the first curve's colour
    // are all failures that the model-level checks above pass straight through.
    // So these drive a real CanvasView through the same mouse events the tools
    // receive and read back its cached display.

    /// A canvas with the standard multi-curve chart loaded, one curve created per
    /// series, each sampled by the colour-picker path and then digitised by the
    /// grid path. Returns the canvas and the curve ids.
    private static func multiCurveCanvas() -> (canvas: CanvasView, ids: [UUID], imageWidth: Int)? {
        let chart = SyntheticChart.renderMulti()
        guard let cg = SampleChartWriter.makeCGImage(from: chart.buffer) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))

        // A window is required: the canvas converts mouse points through it, and
        // without one a flipped view maps y the wrong way up.
        let frame = NSRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        let canvas = CanvasView(frame: frame)
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        canvas.load(image: image)
        // Left at the identity transform, so image pixels and view points
        // coincide and the synthetic ground truth can be aimed at directly.
        canvas.layoutSubtreeIfNeeded()

        func windowPoint(_ p: PixelPoint) -> CGPoint {
            canvas.convert(canvas.viewPoint(fromImage: p), to: nil)
        }
        func click(_ p: PixelPoint) {
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown,
                                                 location: windowPoint(p),
                                                 modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil,
                                                 eventNumber: 0, clickCount: 1,
                                                 pressure: 1) else { return }
            canvas.mouseDown(with: event)
        }

        canvas.tool = .pickLineColor
        var ids: [UUID] = []
        for series in chart.series {
            canvas.addLine()
            guard let id = canvas.state.activeLineID else { return nil }
            ids.append(id)
            click(series.pixels[series.pixels.count / 2])
            guard canvas.state.lines.first(where: { $0.id == id })?.lineColor != nil else {
                return nil
            }
        }

        canvas.tool = .gridDigitize
        for id in ids {
            canvas.selectLine(id: id)
            let start = windowPoint(PixelPoint(x: 2, y: 2))
            let end = windowPoint(PixelPoint(x: Double(cg.width - 2),
                                             y: Double(cg.height - 2)))
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: start,
                                                modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1),
                  let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: end,
                                                modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: end,
                                              modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1)
            else { return nil }
            canvas.mouseDown(with: down)
            canvas.mouseDragged(with: drag)
            canvas.mouseUp(with: up)
        }
        canvas.selectLine(id: ids[0])
        canvas.layoutSubtreeIfNeeded()
        return (canvas, ids, cg.width)
    }

    /// What is on screen right now, row-major RGB at backing resolution.
    private struct RenderedFrame {
        let width: Int, height: Int, rgb: [UInt8]

        func pixel(x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
            guard x >= 0, x < width, y >= 0, y < height else { return nil }
            let i = (y * width + x) * 3
            return (Int(rgb[i]), Int(rgb[i + 1]), Int(rgb[i + 2]))
        }

        /// Saturated = clearly not grey: a curve or a marker disc.
        static func isSaturated(_ p: (r: Int, g: Int, b: Int)) -> Bool {
            max(p.r, max(p.g, p.b)) - min(p.r, min(p.g, p.b)) > 60
        }

        /// The marker halo is white at 95% over a 250-grey chart, so it lands at
        /// 253 or above — brighter than the background it covers.
        static func isHalo(_ p: (r: Int, g: Int, b: Int)) -> Bool {
            p.r >= 253 && p.g >= 253 && p.b >= 253
        }
    }

    private static func render(_ canvas: CanvasView) -> RenderedFrame? {
        canvas.displayIfNeeded()
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard let src = rep.bitmapData else { return nil }
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let s = y * bpr + x * spp, d = (y * w + x) * 3
                out[d] = src[s]; out[d + 1] = src[s + 1]; out[d + 2] = src[s + 2]
            }
        }
        return RenderedFrame(width: w, height: h, rgb: out)
    }

    /// Colour-classified counts in a square window, for the pixel the point
    /// actually sits on. A marker drawn in its curve's own colour with no outline
    /// would leave the window almost entirely "curve"; the halo is what breaks
    /// that up.
    private static func inkTally(_ frame: RenderedFrame, around p: PixelPoint,
                                 scale: Double, radius: Int) -> (curve: Int, halo: Int, other: Int) {
        var curve = 0, halo = 0, other = 0
        let cx = Int(p.x * scale), cy = Int(p.y * scale)
        for dy in -radius...radius {
            for dx in -radius...radius {
                guard let c = frame.pixel(x: cx + dx, y: cy + dy) else { continue }
                if RenderedFrame.isSaturated(c) { curve += 1 }
                else if RenderedFrame.isHalo(c) { halo += 1 }
                else { other += 1 }
            }
        }
        return (curve, halo, other)
    }

    private static func markerHaloIsVisible() -> Bool {
        guard let probe = multiCurveCanvas(), let frame = render(probe.canvas) else { return false }
        let canvas = probe.canvas, ids = probe.ids
        let scale = Double(frame.width) / Double(probe.imageWidth)
        guard let line = canvas.state.lines.first(where: { $0.id == ids[0] }),
              line.points.count > 40 else { return false }
        // Sample the middle of the curve, away from the ringed endpoints, where a
        // marker sits directly on top of its own stroke — the case the halo is
        // there for.
        var halos: [Int] = []
        for index in stride(from: 8, to: line.points.count - 8, by: max(1, line.points.count / 6)) {
            halos.append(inkTally(frame, around: line.orderedPoints[index],
                                  scale: scale, radius: 12).halo)
        }
        return !halos.isEmpty && halos.allSatisfy { $0 >= 40 }
    }

    private static func orderChangesTheLineDrawn() -> Bool {
        guard let probe = multiCurveCanvas(), let before = render(probe.canvas) else { return false }
        let canvas = probe.canvas, ids = probe.ids
        canvas.setOrder(.reversed, for: ids[0])
        canvas.layoutSubtreeIfNeeded()
        guard let after = render(canvas) else { return false }
        var changed = 0
        for i in 0..<min(before.rgb.count, after.rgb.count) {
            let d = abs(Int(before.rgb[i]) - Int(after.rgb[i]))
            if d > 30 { changed += 1 }
        }
        // The polyline is the only thing order controls, so a reversal has to
        // repaint a substantial number of pixels. Zero would mean it is not drawn
        // at all, which is the failure mode this guards.
        return changed > 5_000
    }

    private static func eachCurveKeepsItsOwnColour() -> Bool {
        guard let probe = multiCurveCanvas(), let frame = render(probe.canvas) else { return false }
        let canvas = probe.canvas, ids = probe.ids
        let scale = Double(frame.width) / Double(probe.imageWidth)
        let expected = SyntheticChart.multiCurveColors
        guard ids.count >= expected.count else { return false }

        for (index, id) in ids.enumerated() {
            guard let line = canvas.state.lines.first(where: { $0.id == id }),
                  line.points.count > 20 else { return false }
            // The colours are deliberately far apart, so the nearest expected
            // colour to a saturated pixel must be the right one — and the other
            // curves must never claim it.
            var mine = 0, theirs = 0
            for index2 in stride(from: 5, to: line.points.count - 5, by: max(1, line.points.count / 8)) {
                let p = line.orderedPoints[index2]
                guard let c = frame.pixel(x: Int(p.x * scale), y: Int(p.y * scale)),
                      RenderedFrame.isSaturated(c) else { continue }
                var best = 0, bestDistance = Double.infinity
                for (k, candidate) in expected.enumerated() {
                    let d = Double((c.r - Int(candidate.r)) * (c.r - Int(candidate.r))
                                   + (c.g - Int(candidate.g)) * (c.g - Int(candidate.g))
                                   + (c.b - Int(candidate.b)) * (c.b - Int(candidate.b)))
                    if d < bestDistance { bestDistance = d; best = k }
                }
                if best == index { mine += 1 } else { theirs += 1 }
            }
            if mine == 0 || theirs > 0 { return false }
        }
        return true
    }

    // MARK: - Calibration entry points

    /// A calibration must not be replaceable by accident.
    ///
    /// `beginCalibration(force: false)` is the whole guard: it has to refuse, and
    /// it has to leave the calibration, the extracted points and the active tool
    /// exactly as they were. The failure this catches is the app going straight
    /// to `canvas.tool = .setScale`, which silently wiped an existing coordinate
    /// system the moment the button was touched.
    private static func beginCalibrationRefusal() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas() else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        let anchors = CalibrationAnchors(xStart: PixelPoint(x: 86, y: 488),
                                         xEnd: PixelPoint(x: 700, y: 488),
                                         yStart: PixelPoint(x: 90, y: 560),
                                         yEnd: PixelPoint(x: 90, y: 100))
        canvas.applyCalibration(anchors: anchors,
                                xStartValue: 0, xEndValue: 1,
                                yStartValue: 0, yEndValue: 10,
                                xIsLogarithmic: false, yIsLogarithmic: false)
        let before = canvas.state.calibration
        let pointsBefore = canvas.state.totalPointCount
        canvas.tool = .browse

        let started = canvas.beginCalibration(force: false)
        let refused = !started
            && canvas.state.calibration == before
            && canvas.state.calibrationAnchors == anchors
            && canvas.state.totalPointCount == pointsBefore
            && canvas.tool == .browse

        // ...and forcing it does go through, clearing the old mapping so the
        // four new clicks cannot be mixed with the old anchors.
        let forced = canvas.beginCalibration(force: true)
            && canvas.state.calibration == nil
            && canvas.tool == .setScale

        return (refused && forced,
                refused && forced
                    ? "未确认时保持原标定 · 确认后清除并进入标定"
                    : "拒绝=\(refused ? "是" : "否") 强制=\(forced ? "是" : "否")")
    }

    /// A map built without anchors still draws its rules from the fallback.
    ///
    /// The canvas reaches this only for a map that arrived without anchors (one
    /// built before `CalibrationAnchors` existed). `state` is read-only from
    /// outside, so this drives the fallback directly rather than through the
    /// view — the point is that the corner comes out where the rules expect.
    private static func calibrationFallbackAnchorsAreUsable() -> Bool {
        let map = CalibrationMap(
            x: AxisCalibration(pixelMin: 120, valueMin: 0, pixelMax: 700, valueMax: 1),
            y: AxisCalibration(pixelMin: 500, valueMin: 0, pixelMax: 90, valueMax: 10))
        let anchors = CalibrationAnchors(fallbackFrom: map)
        return anchors.xStart == PixelPoint(x: 120, y: 500)
            && anchors.yStart == PixelPoint(x: 120, y: 500)
            && anchors.xEnd == PixelPoint(x: 700, y: 500)
            && anchors.yEnd == PixelPoint(x: 120, y: 90)
    }

    /// Correcting a figure is not re-tracing an axis: the four markers must stay
    /// exactly where the user clicked them while the mapping takes the new
    /// numbers. Rebuilding the anchors from the map instead would quietly slide
    /// every marker onto the axes' low corner.
    private static func editingValuesKeepsTheMarkers() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas() else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        // Deliberately *not* a corner: the X rule sits well above the Y rule's
        // start, so anything that rebuilds anchors from the map lands elsewhere
        // and the comparison notices.
        let anchors = CalibrationAnchors(xStart: PixelPoint(x: 86, y: 488),
                                         xEnd: PixelPoint(x: 700, y: 488),
                                         yStart: PixelPoint(x: 90, y: 560),
                                         yEnd: PixelPoint(x: 90, y: 100))
        canvas.applyCalibration(anchors: anchors,
                                xStartValue: 0, xEndValue: 1,
                                yStartValue: 0, yEndValue: 10,
                                xIsLogarithmic: false, yIsLogarithmic: false)

        let edited = CalibrationMap(anchors: anchors,
                                    xStartValue: 2, xEndValue: 9,
                                    yStartValue: 100, yEndValue: 200)
        canvas.updateCalibrationValues(edited)

        let kept = canvas.state.calibrationAnchors == anchors
        let applied = canvas.state.calibration?.x.valueMax == 9
            && canvas.state.calibration?.y.valueMin == 100
        return (kept && applied, kept && applied
            ? "标记未动,数值 0→2 / 10→200 已生效"
            : "标记被移动=\(kept ? "否" : "是") 数值生效=\(applied ? "是" : "否")")
    }

    /// The step prompt above the canvas has to move on with every anchor the
    /// user places: it is the only thing that says which click is being asked
    /// for, and the anchor set it is derived from is filled in by the canvas.
    ///
    /// It did not move. `mouseDown` appended the pixel and repainted, but never
    /// told the delegate, so the strip read 「标定 1/4:点取 X 起始」 from the
    /// moment the tool was picked until the fourth click opened the sheet —
    /// while the ①②③ markers on the chart, drawn from the very same array,
    /// advanced normally. A prompt that is merely late reads as a stale one; a
    /// prompt that says "X 起始" when the user is placing "Y 起始" reads as a
    /// wrong instruction, which is how this was reported.
    ///
    /// Counting delegate notifications is the only way to catch it. The prompt
    /// string is correct at every instant — reading it back after the clicks
    /// gets 4/4 either way — because the bug is not in the prompt but in the
    /// *re-asking*, so what has to be checked is the sequence of values the
    /// strip was told to show, not the value it holds at the end.
    private static func calibrationPromptAdvancesWithEachClick() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas() else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        let collector = CalibrationPromptProbe()
        canvas.delegate = collector

        func windowPoint(_ p: PixelPoint) -> CGPoint {
            canvas.convert(canvas.viewPoint(fromImage: p), to: nil)
        }
        func click(_ p: PixelPoint) -> Bool {
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint(p),
                                                 modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1)
            else { return false }
            canvas.mouseDown(with: event)
            return true
        }

        canvas.tool = .setScale
        // Four clicks that make a usable calibration, spread out enough that the
        // X rule and the Y rule are clearly distinct pairs — the order is the
        // only thing under test, but a degenerate set would trip the sheet's own
        // validation if this ever grew into a full flow.
        let anchors = [PixelPoint(x: 120, y: 500), PixelPoint(x: 690, y: 500),
                       PixelPoint(x: 120, y: 480), PixelPoint(x: 120, y: 90)]
        for anchor in anchors {
            guard click(anchor) else { return (false, "无法合成点击") }
        }

        // What the strip should have been told, in order. The first entry comes
        // from arming the tool, so it is the "nothing placed yet" state.
        let expected = ["标定 1/4:点取X 起始", "标定 2/4:点取X 末端",
                        "标定 3/4:点取Y 起始", "标定 4/4:点取Y 末端"]
        // One hand-over for the four clicks, and one prompt per anchor: the two
        // counters answer different questions, so both are asserted.
        let passed = collector.prompts == expected && collector.collected == 1
        return (passed, passed
            ? expected.joined(separator: " → ")
            : "实际=\(collector.prompts.isEmpty ? "一次都没更新" : collector.prompts.joined(separator: " → "))"
                + " · 交出锚点 \(collector.collected) 次")
    }

    /// Records the prompt the strip would be showing after each notification,
    /// exactly as `refreshUI` reads it — the delegate's whole job here is to
    /// prove it was asked.
    private final class CalibrationPromptProbe: CanvasViewDelegate {
        private(set) var prompts: [String] = []
        private(set) var collected = 0

        func canvas(_ canvas: CanvasView, didCollectScalePoints anchors: CalibrationAnchors) {
            collected += 1
        }
        func canvasDidChangeState(_ canvas: CanvasView) {
            if let prompt = canvas.scalePrompt { prompts.append(prompt) }
        }
        func canvas(_ canvas: CanvasView, didFailWith message: String) {}
    }

    // MARK: - Calibration overlay, on rendered pixels

    /// The four anchors a handle probe works with, placed in the synthetic
    /// chart's open space.
    ///
    /// The chart's sigmoid is the only saturated ink the page already carries,
    /// and a handle is detected *by* saturation — so an anchor sitting on the
    /// curve would make the two indistinguishable and the check would pass
    /// whatever the canvas drew. These sit well clear of it: the X rule below
    /// the flat left of the sigmoid, the Y rule in the empty right half, and the
    /// four far enough apart that none lands in another's measurement window
    /// (and none within the reveal radius of another).
    private static let handleProbeAnchors = [
        PixelPoint(x: 110, y: 560),   // X 起始
        PixelPoint(x: 840, y: 560),   // X 末端
        PixelPoint(x: 460, y: 560),   // Y 起始
        PixelPoint(x: 460, y: 60),    // Y 末端
    ]

    /// A calibrated canvas in 浏览 with the pointer nowhere near it — the state
    /// the app is in the moment the sheet is confirmed.
    private static func calibratedBrowseCanvas()
        -> (canvas: CanvasView, imageWidth: Int, window: NSWindow)? {
        guard let probe = singleCurveCanvas() else { return nil }
        let canvas = probe.canvas
        let a = handleProbeAnchors
        canvas.applyCalibration(anchors: CalibrationAnchors(xStart: a[0], xEnd: a[1],
                                                            yStart: a[2], yEnd: a[3]),
                                xStartValue: 0, xEndValue: 10,
                                yStartValue: 0, yEndValue: 5,
                                xIsLogarithmic: false, yIsLogarithmic: false)
        canvas.tool = .browse
        return (canvas, probe.imageWidth, probe.window)
    }

    /// Moves the pointer to an image point the way the window would.
    private static func hover(_ canvas: CanvasView, at p: PixelPoint) -> Bool {
        let location = canvas.convert(canvas.viewPoint(fromImage: p), to: nil)
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: location,
                                             modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil,
                                             eventNumber: 0, clickCount: 0, pressure: 0)
        else { return false }
        canvas.mouseMoved(with: event)
        return true
    }

    /// Saturated ink in a square window around an anchor: the handle's disc, its
    /// label pill, and whatever the chart and the calibration rules already had
    /// there.
    ///
    /// Wide enough to hold the disc and the whole pill that trails it — the pill
    /// starts 11pt right of the anchor and runs another 30pt or so — and still
    /// short of the next anchor's window, so the four are measured independently.
    /// Only the difference between two frames is read, so the chart's own ink and
    /// the dashed rules in the window cancel out.
    private static func inkAround(_ frame: RenderedFrame, _ p: PixelPoint, scale: Double) -> Int {
        inkTally(frame, around: p, scale: scale, radius: 56).curve
    }

    /// The four handles are drag targets for nudging an axis, not part of the
    /// chart. Once the coordinate system is confirmed they have to get out of the
    /// way, and come back only when the pointer is brought near one.
    ///
    /// They did not: after 标定 the chart was read through two large coloured
    /// discs with `@(116, 488)` printed beside them, sitting in the middle of the
    /// data. The check runs three states and reads the pixels of each, because
    /// the model is the same in all three — every assertion above this line
    /// passes with the discs drawn over everything.
    ///
    /// ① pointer off the canvas: no disc anywhere; ② pointer on a handle: all
    /// four back — the whole set, not just the nearest, since a lone disc says
    /// nothing about which axis it belongs to; ③ pointer away again: gone.
    private static func calibrationHandlesStayOutOfTheWay() -> (passed: Bool, detail: String) {
        guard let probe = calibratedBrowseCanvas(),
              let clean = render(probe.canvas) else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        let scale = Double(clean.width) / Double(probe.imageWidth)
        let anchors = handleProbeAnchors

        let hidden = anchors.map { inkAround(clean, $0, scale: scale) }

        // Onto the first handle. The whole set has to come back, not just that
        // one, so all four windows are measured.
        guard hover(canvas, at: anchors[0]),
              let revealed = render(canvas) else { return (false, "无法合成鼠标移动") }
        let shown = anchors.map { inkAround(revealed, $0, scale: scale) }

        // And away again — far from all four, but still on the canvas.
        guard hover(canvas, at: PixelPoint(x: 720, y: 240)),
              let again = render(canvas) else { return (false, "无法合成鼠标移动") }
        let hiddenAgain = anchors.map { inkAround(again, $0, scale: scale) }

        // Measured growth is 1162–1434 pixels per anchor, and 0 when nothing is
        // drawn — the disc alone accounts for about 600 of it. The threshold sits
        // well clear of both ends rather than snug against the observed minimum,
        // so a glyph-metric change that trims the pill cannot turn this red.
        let growth = zip(shown, hidden).map { $0 - $1 }
        let settled = zip(hiddenAgain, hidden).map { abs($0 - $1) }
        let passed = growth.allSatisfy { $0 > 800 } && settled.allSatisfy { $0 <= 200 }
        return (passed, passed
            ? "未靠近 0 墨 · 靠近 +\(growth.min() ?? 0)…+\(growth.max() ?? 0) 像素 · 移开回到原样"
            : "靠近前后增量 \(growth) · 移开后与初始差 \(settled)")
    }

    /// The handle's label is the numbered step and the value it maps to, and
    /// nothing else — in particular not the anchor's pixel.
    ///
    /// It carried `@(116, 488)`. That is the readout the user asked to be rid of:
    /// a pixel coordinate beside a marker on a chart that already reads in its
    /// own units, and the widest part of the pill that was sitting on the data.
    ///
    /// Pinned as a string rather than measured off a rendered frame. The label
    /// sits on the X rule's own row, so a rendered width would be measuring the
    /// dashed rule running through the same band — the first attempt at this did
    /// exactly that and read 730pt, which is the rule's own length.
    private static func calibrationHandleLabelsDropThePixelReadout() -> (passed: Bool, detail: String) {
        let samples = [("①", "0"), ("②", "10"), ("③", "2.5"), ("④", "-1.5e-3")]
        let expected = ["① 0", "② 10", "③ 2.5", "④ -1.5e-3"]
        let actual = samples.map { CanvasView.handleLabel(step: $0.0, value: $0.1) }
        let clean = actual.allSatisfy { !$0.contains("@") && !$0.contains("(") && !$0.contains(",") }
        let passed = actual == expected && clean
        return (passed, passed
            ? "「\(actual.joined(separator: "」「"))」· 无 @、无括号逗号"
            : "实际 「\(actual.joined(separator: "」「"))」· 与预期不符或无括号=\(clean ? "是" : "否")")
    }

    /// A row of the calibration sheet is three columns — the value's name, the
    /// pixel the anchor was clicked at, and the value field — and no two of them
    /// may overlap.
    ///
    /// They did. The hint sat at a fixed x=130 inside a 150pt box while the
    /// value field began at x=190, so the two crossed by 90pt on *every* anchor,
    /// not just wide ones; the field is added later, so it was drawn on top and
    /// the pixel readout simply disappeared under it. The hint is the only thing
    /// on the sheet tying a typed number to a mark on the chart, which makes a
    /// silently hidden one worse than a missing field would be.
    ///
    /// The anchors used here are the widest the app can plausibly meet — five
    /// and six figures — because a column sized from font metrics has to hold up
    /// where a hand-picked constant failed. `像素 (0, 0)` is 53.5pt of label and
    /// a five-figure coordinate 104.9pt: a 2× spread that no single fixed width
    /// covers.
    ///
    /// The hint is measured through its own cell, not through the string it
    /// holds. A cell keeps 4pt for itself, so a string-width comparison passes
    /// while the label on screen shows `像素 (12345, 678…` — which is exactly
    /// what an earlier version of this check did.
    private static func calibrationFormColumnsDoNotOverlap() -> (passed: Bool, detail: String) {
        let wide = CalibrationAnchors(xStart: PixelPoint(x: 12_345, y: 67_890),
                                      xEnd: PixelPoint(x: 54_321, y: 67_890),
                                      yStart: PixelPoint(x: 111, y: 98_765),
                                      yEnd: PixelPoint(x: 111, y: 12_345))
        let form = CalibrationSheet.Form(anchors: wide, previous: nil)
        form.view.layoutSubtreeIfNeeded()

        guard form.rows.count == 4 else {
            return (false, "表单应有 4 行, 实际 \(form.rows.count)")
        }

        let width = form.columns.width
        var widest = 0.0
        for (index, row) in form.rows.enumerated() {
            // Left to right, each column clear of the next, all inside the sheet.
            // Touching is not enough: a hint flush against the field reads as
            // part of it.
            guard row.name.frame.maxX <= row.hint.frame.minX,
                  row.hint.frame.maxX <= row.field.frame.minX,
                  row.name.frame.minX >= 0,
                  row.field.frame.maxX <= width + 0.5 else {
                return (false, "第 \(index + 1) 行三列重叠 —— 名字 x\(span(row.name.frame))"
                    + " 像素 x\(span(row.hint.frame)) 输入 x\(span(row.field.frame))"
                    + " · 表单宽 \(Int(width))")
            }
            // The hint must fit whole. A column sized to the string cannot
            // truncate it; a column sized to a constant can, and a truncated
            // coordinate is a wrong coordinate.
            let needed = row.hint.cell!
                .cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000,
                                            height: row.hint.frame.height)).width
            guard needed <= row.hint.frame.width + 0.5 else {
                return (false, "第 \(index + 1) 行像素提示被裁: 需要 \(one(needed))pt, "
                    + "列宽只有 \(one(row.hint.frame.width))pt")
            }
            widest = max(widest, needed)
        }

        // And the sheet must not stretch without limit. The hint column gives up
        // its own width to hold this, so the check is what would catch that
        // trade being removed.
        guard width <= CalibrationSheet.Form.Columns.maximumWidth + 0.5 else {
            return (false, "六位数坐标把表单撑到 \(Int(width))pt, "
                + "上限 \(Int(CalibrationSheet.Form.Columns.maximumWidth))pt")
        }

        // The ordinary case must be untouched. A calibration on a small image
        // looked right before and has to keep looking that way — the sheet is
        // only allowed to grow when a hint actually needs the room.
        let small = CalibrationAnchors(xStart: PixelPoint(x: 117, y: 432),
                                       xEnd: PixelPoint(x: 725, y: 432),
                                       yStart: PixelPoint(x: 87, y: 461),
                                       yEnd: PixelPoint(x: 87, y: 73))
        let plain = CalibrationSheet.Form(anchors: small, previous: nil)
        guard abs(plain.columns.width - CalibrationSheet.Form.Columns.widthFloor) < 0.5 else {
            return (false, "小图上的表单宽度从 460pt 变成了 \(Int(plain.columns.width))pt")
        }
        // The four rows in that case must still be clear of each other; the
        // width floor must not be holding a genuine overlap down.
        for (index, row) in plain.rows.enumerated()
        where row.name.frame.maxX > row.hint.frame.minX
            || row.hint.frame.maxX > row.field.frame.minX {
            return (false, "小图第 \(index + 1) 行三列重叠 —— 名字 x\(span(row.name.frame))"
                + " 像素 x\(span(row.hint.frame)) 输入 x\(span(row.field.frame))")
        }

        return (true, "三列不重叠 · 最宽提示 \(one(widest))pt / 列宽 \(one(form.columns.hintWidth))pt"
            + " · 六位数表单 \(Int(width))pt / 小图 \(Int(plain.columns.width))pt")
    }

    private static func span(_ r: NSRect) -> String {
        "\(one(r.minX))..\(one(r.maxX))"
    }

    private static func one(_ v: CGFloat) -> String {
        String(format: "%.1f", v)
    }

    /// The row a tick is drawn on follows its own axis rule.
    ///
    /// The three-point scheme could place an X tick at "the origin's row",
    /// because that row *was* the X rule. Four anchors break that: the X rule's
    /// two ends may sit at different rows, and the Y rule's start row is
    /// unrelated. A tick placed at either single anchor's coordinate would
    /// visibly float off a rule drawn square, so this pins the interpolation —
    /// including the degenerate case, where a rule with no vertical extent must
    /// return its start instead of dividing by zero.
    private static func ticksFollowTheirOwnRule() -> (passed: Bool, detail: String) {
        // A rule sloping from row 500 down to row 100 across columns 100…900.
        // Its midpoint must land halfway, not on either end.
        let mid = CanvasView.interpolate(500, from: 100, to: 900,
                                         startValue: 500, endValue: 100)
        let quarter = CanvasView.interpolate(300, from: 100, to: 900,
                                             startValue: 500, endValue: 100)
        // A rule with no slope: every tick sits on the one row it has.
        let flat = CanvasView.interpolate(700, from: 100, to: 900,
                                          startValue: 488, endValue: 488)
        // A degenerate rule (both ends the same column) must not divide by zero.
        let degenerate = CanvasView.interpolate(100, from: 100, to: 100,
                                                startValue: 488, endValue: 200)
        let passed = abs(mid - 300) < 1e-9 && abs(quarter - 400) < 1e-9
            && abs(flat - 488) < 1e-9 && abs(degenerate - 488) < 1e-9
        return (passed, passed
            ? "中点 \(Int(mid)) · 水平规则 \(Int(flat)) · 退化 \(Int(degenerate))"
            : "中点 \(mid) 四分之一 \(quarter) 水平 \(flat) 退化 \(degenerate)")
    }

    /// Reads the rendered canvas to prove the ticks ride their own rule.
    ///
    /// `isSaturated` cannot be used for this: it only says "not grey", and the
    /// rules are drawn over a chart that has coloured curves on it. So the test
    /// is specifically blue-dominant (the X rule's colour).
    private static func isAxisBlue(_ c: (r: Int, g: Int, b: Int)) -> Bool {
        c.b > c.r + 40 && c.b > c.g + 40
    }

    /// The rows the X axis' ticks are painted on, measured off the pixels.
    ///
    /// Two renderings of the same chart are compared: one with a sloping X rule
    /// and one with a flat rule at that same start row. If a tick rides the rule
    /// its ink moves with it, so the two disagree by the rule's drop; if a tick
    /// were pinned to the start anchor's row — the three-point habit, where that
    /// row *was* the rule — the two would be identical and the shift would be
    /// zero. Only the *shift* is compared, because `isAxisBlue` also catches
    /// pieces of the chart and an absolute row would be at their mercy.
    ///
    /// Columns come from the tick generator rather than a fixed stride, so the
    /// probe lands on ink instead of sampling the gaps between ticks.
    /// Where the Y rule is painted, as a column, at a given row.
    ///
    /// The Y rule is placed in the blank margin left of the plot, so unlike the
    /// X rule — which runs through the chart's own ink — its column can be read
    /// directly: the mean column of non-grey ink in a short row band.
    private static func yRuleColumn(yStartX: Double, row: Double) -> Double? {
        guard let probe = singleCurveCanvas() else { return nil }
        let canvas = probe.canvas
        // The Y rule is vertical at its own column; the X rule is parked far to
        // the right so nothing of it reaches the band being read.
        let anchors = CalibrationAnchors(xStart: PixelPoint(x: 300, y: 470),
                                         xEnd: PixelPoint(x: 640, y: 470),
                                         yStart: PixelPoint(x: yStartX, y: 545),
                                         yEnd: PixelPoint(x: yStartX, y: 420))
        canvas.applyCalibration(anchors: anchors,
                                xStartValue: 0, xEndValue: 1,
                                yStartValue: 0, yEndValue: 10,
                                xIsLogarithmic: false, yIsLogarithmic: false)
        guard let frame = render(canvas) else { return nil }
        let scale = Double(frame.width) / Double(probe.imageWidth)
        let cy = Int(row * scale)

        // The rule is the *rightmost* teal ink in the band: its tick labels are
        // drawn to its left, so a mean over the band would be dragged towards
        // them and read a column the rule was never drawn at.
        var rightmost: Double?
        for column in 0..<Int(250 * scale) {
            for dy in -2...2 {
                guard let c = frame.pixel(x: column, y: cy + dy) else { continue }
                if isAxisTeal(c) { rightmost = Double(column) / scale }
            }
        }
        return rightmost
    }

    private static func isAxisTeal(_ c: (r: Int, g: Int, b: Int)) -> Bool {
        c.g > c.r + 30 && c.b > c.r + 30 && abs(c.g - c.b) < 60
    }

    /// Reads the rendered canvas to prove each rule is drawn between its own two
    /// clicked anchors, rather than from a shared corner.
    ///
    /// This is the claim four anchors exist for, and it is the one the old
    /// three-point drawing code got wrong: it drew the Y rule from the *origin*
    /// to the Y end, so moving the Y rule's own start had no effect on the
    /// picture. The probe places the Y rule's start 60pt left of the X rule's
    /// start — the "two axes that do not meet" case — and reads back where the
    /// Y rule was painted. Drawing from a shared corner would put it at the X
    /// rule's column instead.
    private static func calibrationRulesPaintWhereTheyWereClicked()
        -> (passed: Bool, detail: String) {
        // 40 is well left of the X rule at 300, so drawing from a shared corner
        // would put the Y rule at 300 and fail loudly.
        let column = 40.0
        guard let nearStart = yRuleColumn(yStartX: column, row: 530),
              let nearEnd = yRuleColumn(yStartX: column, row: 435) else {
            return (false, "没测到 Y 规则像素")
        }
        let worst = max(abs(nearStart - column), abs(nearEnd - column))
        let passed = worst <= 3
        return (passed, passed
            ? String(format: "Y 规则画在自身锚点列 %.0f(起点 %.1f,末端 %.1f)", column,
                     nearStart, nearEnd)
            : String(format: "Y 规则偏离锚点列:起点 %.1f,末端 %.1f(应为 %.0f)",
                     nearStart, nearEnd, column))
    }

    // MARK: - Eraser and re-digitise
    //
    // The two tools the request asked for. Both are "the thing you see is what
    // you get" tools: the circle drawn under the pointer is what gets erased, and
    // the rectangle drawn orange is the stretch that gets re-taken. Which points
    // those geometry tests land on is invisible in the model — a ring twice the
    // size still erases *something* — so these pick the points that go from the
    // real view, aimed at real curve pixels, and compare against the circle
    // recomputed here.

    /// A canvas with the plain chart loaded and its curve digitised, so a tool
    /// has real points to act on. The view is left at the identity transform
    /// unless `zoomed`, which halves the window so `zoomToFit` has to scale down.
    private static func singleCurveCanvas(zoomed: Bool = false)
        -> (canvas: CanvasView, id: UUID, imageWidth: Int, window: NSWindow)? {
        let chart = SyntheticChart.render()
        guard let cg = SampleChartWriter.makeCGImage(from: chart.buffer) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))

        let divisor: CGFloat = zoomed ? 2 : 1
        let frame = NSRect(x: 0, y: 0, width: CGFloat(cg.width) / divisor,
                           height: CGFloat(cg.height) / divisor)
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        let canvas = CanvasView(frame: frame)
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        canvas.load(image: image)
        canvas.layoutSubtreeIfNeeded()
        if zoomed { _ = canvas.zoomToFit() }

        func windowPoint(_ p: PixelPoint) -> CGPoint {
            canvas.convert(canvas.viewPoint(fromImage: p), to: nil)
        }
        func event(_ type: NSEvent.EventType, _ p: PixelPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: windowPoint(p), modifierFlags: [],
                               timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }

        canvas.tool = .pickLineColor
        canvas.addLine()
        guard let id = canvas.state.activeLineID else { return nil }
        let seed = chart.curvePixels[chart.curvePixels.count / 2]
        guard let pick = event(.leftMouseDown, seed) else { return nil }
        canvas.mouseDown(with: pick)
        guard canvas.state.lines.first(where: { $0.id == id })?.lineColor != nil else { return nil }

        canvas.tool = .gridDigitize
        canvas.selectLine(id: id)
        guard let down = event(.leftMouseDown, PixelPoint(x: 2, y: 2)),
              let drag = event(.leftMouseDragged, PixelPoint(x: Double(cg.width - 2),
                                                             y: Double(cg.height - 2))),
              let up = event(.leftMouseUp, PixelPoint(x: Double(cg.width - 2),
                                                      y: Double(cg.height - 2)))
        else { return nil }
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: drag)
        canvas.mouseUp(with: up)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, id, cg.width, window)
    }

    /// The points of `line` that lie inside the eraser's circle centred on `p`,
    /// computed the way the tool documents: the radius is in view points and the
    /// points are in image pixels, so the circle has to be scaled into image
    /// space before it is compared.
    private static func pointsWithin(_ points: [PixelPoint], of p: PixelPoint,
                                     viewRadius: Double, scale: Double) -> [PixelPoint] {
        let r = viewRadius / max(scale, 0.0001)
        return points.filter { hypot($0.x - p.x, $0.y - p.y) <= r }
    }

    private static func eraserRemovesExactlyTheRing() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas(),
              let line = probe.canvas.state.lines.first(where: { $0.id == probe.id }),
              line.points.count > 40 else { return (false, "无法构建带点的画布") }
        let canvas = probe.canvas, before = line.points

        // Centre the ring on a real point in the middle of the run, so its edge
        // lands on markers: centred in blank space a radius that is off by a
        // whole step still removes nothing extra and the check would pass.
        let center = before[before.count / 2]
        // Wide enough to take a real run of points, not a token one or two: the
        // boundary is only tested if there are points on both sides of it.
        let viewRadius: CGFloat = 48
        canvas.eraserRadius = viewRadius

        let gone = pointsWithin(before, of: center, viewRadius: Double(viewRadius),
                                scale: canvas.viewScale)
        let kept = before.filter { !gone.contains($0) }
        guard gone.count >= 2, kept.count >= 2 else {
            return (false, "圆圈附近点太少,测不出边界(内 \(gone.count) 外 \(kept.count))")
        }

        let removed = canvas.erase(at: center)
        let after = canvas.state.lines.first(where: { $0.id == probe.id })!.points
        let okRemoved = removed == gone.count && after.count == kept.count

        // Not just the count: the survivors must be exactly the points outside
        // the circle, so a wrong *centre* cannot pass by deleting the same total.
        let leftOver = after.filter { !kept.contains($0) }
        let lost = kept.filter { !after.contains($0) }
        let passed = okRemoved && leftOver.isEmpty && lost.isEmpty
        return (passed, passed
            ? "半径 \(Int(viewRadius))pt · 删 \(removed) 留 \(after.count)"
            : "删了 \(removed) 应 \(gone.count);误删 \(leftOver.count);误留 \(lost.count)")
    }

    /// The same circle, at a zoom other than 100%.
    ///
    /// This is the check that fails if the tool forgets the radius is measured in
    /// view points: at a scale of ~0.5 an unscaled radius covers half the image
    /// area it should, and the two candidate circles — scaled and not — are made
    /// to disagree before anything is erased, so the check cannot pass by luck.
    private static func eraserRingFollowsZoom() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas(zoomed: true),
              let line = probe.canvas.state.lines.first(where: { $0.id == probe.id }),
              line.points.count > 40 else { return (false, "无法构建缩放画布") }
        let canvas = probe.canvas, scale = canvas.viewScale, before = line.points
        guard scale < 0.9 else { return (false, "窗口没产生缩放(\(String(format: "%.2f", scale)))") }

        let viewRadius: CGFloat = 48
        // The wrong reading: treat the view-point radius as image pixels.
        let wrongRadius = Double(viewRadius)

        // Find a centre where the two circles differ, so the check has something
        // to tell apart rather than being satisfied by both being the same set.
        var center: PixelPoint?
        for index in stride(from: before.count / 4, to: before.count * 3 / 4, by: 3) {
            let candidate = before[index]
            let right = pointsWithin(before, of: candidate, viewRadius: Double(viewRadius),
                                     scale: scale)
            let wrong = before.filter { hypot($0.x - candidate.x, $0.y - candidate.y) <= wrongRadius }
            if right.count > wrong.count + 1 { center = candidate; break }
        }
        guard let center else { return (false, "找不到两种半径结果不同的位置") }

        let shouldGo = pointsWithin(before, of: center, viewRadius: Double(viewRadius), scale: scale)
        let unzoomedWouldGo = before.filter {
            hypot($0.x - center.x, $0.y - center.y) <= wrongRadius
        }

        canvas.eraserRadius = viewRadius
        canvas.erase(at: center)
        let after = canvas.state.lines.first(where: { $0.id == probe.id })!.points
        let kept = before.filter { !shouldGo.contains($0) }
        let missed = shouldGo.filter { after.contains($0) }
        let extra = after.filter { !kept.contains($0) }
        let passed = missed.isEmpty && extra.isEmpty && shouldGo.count > unzoomedWouldGo.count
        return (passed, passed
            ? String(format: "缩放 %.0f%% · 删 %d(不换算只会删 %d)", scale * 100,
                     shouldGo.count, unzoomedWouldGo.count)
            : "漏删 \(missed.count) 误删 \(extra.count)")
    }

    /// A drag has to erase along the whole path, not only where the button went
    /// down. The path follows the curve itself, so every point the pointer passed
    /// over is at distance zero from one of the circles and must be gone.
    private static func eraserDragErasesAlongThePath() -> Bool {
        guard let probe = singleCurveCanvas() else { return false }
        let canvas = probe.canvas
        guard let start = canvas.state.lines.first(where: { $0.id == probe.id })?.points else {
            return false
        }
        guard start.count > 40 else { return false }
        let lower = start.count / 4, upper = start.count / 2
        let path = Array(start[lower...upper])

        func event(_ type: NSEvent.EventType, _ p: PixelPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type,
                               location: canvas.convert(NSPoint(x: p.x, y: p.y), to: nil),
                               modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }

        canvas.tool = .eraser
        canvas.eraserRadius = 18
        guard let down = event(.leftMouseDown, path[0]) else { return false }
        canvas.mouseDown(with: down)
        for point in path.dropFirst() {
            guard let drag = event(.leftMouseDragged, point) else { return false }
            canvas.mouseDragged(with: drag)
        }
        guard let up = event(.leftMouseUp, path[path.count - 1]) else { return false }
        canvas.mouseUp(with: up)

        let after = canvas.state.lines.first(where: { $0.id == probe.id })!.points
        // Every point the pointer sat on went...
        let survivorsOnPath = path.filter { after.contains($0) }
        // ...and the far ends, well clear of the smallest circle, did not.
        let radius = Double(canvas.eraserRadius) / max(canvas.viewScale, 0.0001)
        let tail = start.filter { $0.x > path[path.count - 1].x + radius }
        let tailKept = tail.allSatisfy { after.contains($0) }
        return survivorsOnPath.isEmpty && tailKept && after.count < start.count && !after.isEmpty
    }

    /// The radius must stop at either end of its range rather than take whatever
    /// it is given: the info bar's buttons and the `[` `]` keys both let the user
    /// walk past the end, and a radius of -50 would erase a circle of nothing
    /// while reporting that it had done something.
    private static func eraserRadiusClampsWithoutRecursing() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas() else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        canvas.eraserRadius = 10_000
        let high = canvas.eraserRadius
        canvas.eraserRadius = -50
        let low = canvas.eraserRadius
        canvas.eraserRadius = CanvasView.eraserDefaultRadius
        let back = canvas.eraserRadius
        let passed = high == CanvasView.eraserMaxRadius
            && low == CanvasView.eraserMinRadius
            && back == CanvasView.eraserDefaultRadius
        return (passed, "上限 \(Int(high)) · 下限 \(Int(low)) · 默认 \(Int(back))")
    }

    /// The region the user draws is cleared and that same stretch taken again.
    ///
    /// The strongest thing to assert is that the point count comes back to what
    /// it was: clearing without refilling would drop it, and refilling without
    /// clearing would nearly double it. Both are one-line mistakes that leave a
    /// plausible-looking curve on screen.
    private static func redigitizeReplacesTheRegion() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas(),
              let line = probe.canvas.state.lines.first(where: { $0.id == probe.id }),
              line.points.count > 40 else { return (false, "无法构建带点的画布") }
        let canvas = probe.canvas, before = line.points

        let lo = before[before.count / 4], hi = before[before.count * 3 / 4]
        let mid = before[before.count / 2]
        // A rectangle whose top edge is deliberately *just* short of a real point:
        // that point sits outside the drawn box but inside the inflation the tool
        // applies, so the pass must take it. Without the inflation it survives,
        // and the survivors are exactly what a too-small tolerance leaves behind.
        let edge = mid.y - CanvasView.pointTolerance / 2
        let rect = CGRect(x: min(lo.x, hi.x), y: edge - 80,
                          width: abs(hi.x - lo.x), height: 80)
        let straggler = mid

        // The region the tool actually matches, recomputed here from the same
        // rule: grown by `pointTolerance` before anything is tested.
        let grown = NSRect(x: rect.minX - CanvasView.pointTolerance,
                           y: rect.minY - CanvasView.pointTolerance,
                           width: rect.width + CanvasView.pointTolerance * 2,
                           height: rect.height + CanvasView.pointTolerance * 2)
        let inRegion = before.filter { grown.contains(NSPoint(x: $0.x, y: $0.y)) }
        guard inRegion.count > 2 else { return (false, "框内点太少(\(inRegion.count))") }
        let outside = before.filter { !grown.contains(NSPoint(x: $0.x, y: $0.y)) }

        guard let down = dragEvent(canvas, .leftMouseDown, rect.origin),
              let drag = dragEvent(canvas, .leftMouseDragged,
                                   CGPoint(x: rect.maxX, y: rect.maxY)),
              let up = dragEvent(canvas, .leftMouseUp, CGPoint(x: rect.maxX, y: rect.maxY))
        else { return (false, "无法构造拖拽事件") }
        canvas.tool = .redigitize
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: drag)
        canvas.mouseUp(with: up)

        let after = canvas.state.lines.first(where: { $0.id == probe.id })!.points
        let lost = outside.filter { !after.contains($0) }
        let fresh = after.filter { !outside.contains($0) }

        // Re-taken points must land on the same pixels they were taken from
        // originally: same colour, same mask, same scan lines. A re-digitise that
        // grabbed the wrong colour or the wrong rectangle would put them
        // elsewhere and still report a healthy count. The window is wide (a
        // couple of scan lines) because the delete radius and the re-scan grid
        // need not coincide to the pixel.
        let strayed = fresh.filter { point in
            !inRegion.contains { hypot($0.x - point.x, $0.y - point.y) <= 24 }
        }
        // The box was drawn to exclude `straggler` by a hair: if the tool did not
        // inflate the region, that point is still on the canvas, and a curve with
        // a stale point sitting in the middle of its re-taken stretch is exactly
        // the artefact the inflation exists to prevent.
        let stragglerSurvived = after.contains(straggler)
        let countHeld = abs(after.count - before.count) <= 4
        let passed = lost.isEmpty && !fresh.isEmpty && strayed.isEmpty
            && countHeld && !stragglerSurvived
        return (passed, passed
            ? "框内 \(inRegion.count) 点 → 重取 \(fresh.count),总数 \(before.count)→\(after.count)"
            : "误删框外 \(lost.count);新点偏离 \(strayed.count);"
              + "边界点残留 \(stragglerSurvived ? 1 : 0);总数 \(before.count)→\(after.count)")
    }

    /// The click-sized case: a mis-click takes one point, and a click in blank
    /// space takes none.
    private static func redigitizeClickRemovesNearest() -> Bool {
        guard let probe = singleCurveCanvas() else { return false }
        let canvas = probe.canvas
        guard let line = canvas.state.lines.first(where: { $0.id == probe.id }),
              line.points.count > 20 else { return false }
        let before = line.points
        let target = before[before.count / 2]

        func click(_ p: PixelPoint) -> Bool {
            guard let down = dragEvent(canvas, .leftMouseDown, CGPoint(x: p.x, y: p.y)),
                  let up = dragEvent(canvas, .leftMouseUp, CGPoint(x: p.x, y: p.y)) else {
                return false
            }
            canvas.mouseDown(with: down)
            canvas.mouseUp(with: up)
            return true
        }

        canvas.tool = .redigitize
        guard click(target) else { return false }
        guard let afterOne = canvas.state.lines.first(where: { $0.id == probe.id })?.points,
              afterOne.count == before.count - 1, !afterOne.contains(target) else { return false }

        // Somewhere far from every marker: nothing may go.
        var empty: PixelPoint?
        for x in stride(from: 30.0, to: 870.0, by: 40.0) {
            for y in stride(from: 30.0, to: 610.0, by: 40.0) {
                let candidate = PixelPoint(x: x, y: y)
                if before.allSatisfy({ hypot($0.x - x, $0.y - y) > 30 }) {
                    empty = candidate; break
                }
            }
            if empty != nil { break }
        }
        guard let empty else { return false }
        guard click(empty) else { return false }
        let afterTwo = canvas.state.lines.first(where: { $0.id == probe.id })!.points
        return afterTwo.count == afterOne.count
    }

    /// A drag event whose location is already in image space, converted like the
    /// other helpers do.
    private static func dragEvent(_ canvas: CanvasView, _ type: NSEvent.EventType,
                                  _ p: CGPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type,
                           location: canvas.convert(canvas.viewPoint(fromImage: PixelPoint(x: p.x, y: p.y)), to: nil),
                           modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)
    }

    // MARK: - 撤销 (undo)
    //
    // The stack itself — capacity, ordering, the redo branch — is unit-tested in
    // `UndoHistoryTests`, where a bare `Int` makes the sequence of recorded
    // versions readable. What is left for the selftest is the wiring: which
    // actions reach the stack, that a *drag* is one action rather than one per
    // event, and that restoring a state drags the mask cache along with it. All
    // of those need the real canvas and the real mouse handlers.

    /// Press and release at one image pixel, through the handlers the tools are
    /// driven by.
    ///
    /// Both halves: an action is recorded from the *release*, so a check that
    /// stopped at the press would be inspecting a gesture that never closed —
    /// and would pass against a canvas that recorded nothing at all.
    @discardableResult
    private static func click(at p: PixelPoint, on canvas: CanvasView) -> Bool {
        guard let down = dragEvent(canvas, .leftMouseDown, CGPoint(x: p.x, y: p.y)),
              let up = dragEvent(canvas, .leftMouseUp, CGPoint(x: p.x, y: p.y)) else { return false }
        canvas.mouseDown(with: down)
        canvas.mouseUp(with: up)
        return true
    }

    /// The row's 撤销/恢复 control follows the history in *both* directions, and
    /// carries no words.
    ///
    /// Each half matters twice over. A segment that is always live invites a
    /// click that does nothing, which is indistinguishable from a broken one; a
    /// segment that comes and goes with the history moves every other button in
    /// the row. And the two run out at different moments — one 撤销 leaves
    /// something to 恢复 and possibly nothing left to 撤销 — so a control that
    /// gated both halves together would leave a dead segment on screen exactly
    /// when the user reached for it. The three states are checked separately for
    /// that reason; a check that only tried "nothing" against "everything" would
    /// pass against a control wired to a single flag.
    ///
    /// Found by being a segmented control rather than by index or by symbol, so
    /// this also asserts that it is still icon-only: giving the segments labels
    /// would push the window minimum past the smallest screen the app supports.
    private static func historyControlFollowsTheHistory() -> (passed: Bool, detail: String) {
        let toolbar = ToolbarView(frame: NSRect(x: 0, y: 0, width: 1_400,
                                                height: MainLayout.toolbarHeight))
        let segmented = toolbar.subviews.compactMap { $0 as? NSSegmentedControl }
        guard segmented.count == 1, let control = segmented.first, control.segmentCount == 2 else {
            return (false, "分段控件 \(segmented.count) 个(应为 1 个,两段)")
        }

        toolbar.update(isLoadingEnabled: true, canExport: true, canUndo: false, canRedo: false)
        let bothDark = !control.isEnabled(forSegment: 0) && !control.isEnabled(forSegment: 1)
        toolbar.update(isLoadingEnabled: true, canExport: true, canUndo: true, canRedo: false)
        let undoOnly = control.isEnabled(forSegment: 0) && !control.isEnabled(forSegment: 1)
        toolbar.update(isLoadingEnabled: true, canExport: true, canUndo: false, canRedo: true)
        let redoOnly = !control.isEnabled(forSegment: 0) && control.isEnabled(forSegment: 1)
        toolbar.update(isLoadingEnabled: true, canExport: true, canUndo: true, canRedo: true)
        let bothLive = control.isEnabled(forSegment: 0) && control.isEnabled(forSegment: 1)

        let drewSomething = (0..<control.segmentCount).allSatisfy {
            control.image(forSegment: $0) != nil
        }
        let passed = bothDark && undoOnly && redoOnly && bothLive && drewSomething
        return (passed, passed
            ? "无历史两端全灰 → 只可撤销 → 只可恢复 → 两端可用,都带图标"
            : "全灰/只撤/只恢复/都活 = \(bothDark)/\(undoOnly)/\(redoOnly)/\(bothLive)"
                + " · 图标\(drewSomething ? "有" : "无")")
    }

    /// The two segments fire two different callbacks.
    ///
    /// Kept apart from the gating check because they are separate failures. A
    /// control whose two halves both fired 撤销 would look right in *every*
    /// state — enabled, disabled and greyed exactly as it should be — and would
    /// quietly undo when the user asked for 恢复. Nothing else here would notice:
    /// the canvas-level 恢复 check calls `redo()` directly and never goes through
    /// the button, so the wiring from segment to action has to be asserted on its
    /// own.
    ///
    /// Driven through a stand-in control rather than the real one. The row's
    /// control is `.momentary`, and a momentary segmented control does not keep
    /// `selectedSegment` — the selection exists only for the duration of a click,
    /// so setting it from a test leaves the handler reading -1 and firing nothing
    /// (which is exactly how this check first failed). The stand-in is
    /// `.selectOne` for no other reason than that its selection can be set; it is
    /// given the *real* control's target and action, so what it drives is the
    /// shipping handler, reading the same property a real click would have set.
    private static func historySegmentsFireTheirOwnActions() -> (passed: Bool, detail: String) {
        final class Recorder: ToolbarDelegate {
            var undos = 0
            var redos = 0
            func toolbar(_ toolbar: ToolbarView, didSelect tool: ToolMode) {}
            func toolbarDidRequestUndo(_ toolbar: ToolbarView) { undos += 1 }
            func toolbarDidRequestRedo(_ toolbar: ToolbarView) { redos += 1 }
            func toolbarDidRequestCopy(_ toolbar: ToolbarView) {}
            func toolbarDidRequestExport(_ toolbar: ToolbarView, from sender: NSView) {}
            func toolbarDidRequestFit(_ toolbar: ToolbarView) {}
        }
        let toolbar = ToolbarView(frame: NSRect(x: 0, y: 0, width: 1_400,
                                                height: MainLayout.toolbarHeight))
        let recorder = Recorder()
        toolbar.delegate = recorder
        guard let control = toolbar.subviews.compactMap({ $0 as? NSSegmentedControl }).first,
              control.segmentCount == 2 else { return (false, "找不到撤销/恢复分段控件") }
        // A real click only reaches the handler if the control carries both.
        guard control.action != nil, control.target != nil else {
            return (false, "控件没有接上 target/action,真点击不会触发")
        }

        let driver = NSSegmentedControl(labels: ["撤销", "恢复"], trackingMode: .selectOne,
                                        target: control.target, action: control.action)
        driver.selectedSegment = 0
        _ = driver.sendAction(driver.action, to: driver.target)
        driver.selectedSegment = 1
        _ = driver.sendAction(driver.action, to: driver.target)

        let passed = recorder.undos == 1 && recorder.redos == 1
        return (passed, passed
            ? "左段 → 撤销 1 次 · 右段 → 恢复 1 次"
            : "撤销回调 \(recorder.undos) 次(应 1) · 恢复回调 \(recorder.redos) 次(应 1)")
    }

    /// 恢复 hands back exactly what 撤销 took away.
    ///
    /// The counterpart to `undoBringsBackAnErasedStroke`, and the case the stack
    /// unit tests cannot reach: they drive a bare `Int`, so what they prove is
    /// that the entries return in order, not that the *canvas* — states, masks
    /// and all — does. Compared per point for the same reason as the undo check:
    /// a restore that handed back the right number of markers in the wrong
    /// places would pass a count.
    private static func redoPutsBackWhatUndoTookAway() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas(),
              let line = probe.canvas.state.lines.first(where: { $0.id == probe.id }),
              line.points.count > 40 else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        let before = line.points

        canvas.tool = .eraser
        canvas.eraserRadius = 40
        guard click(at: before[before.count / 2], on: canvas) else { return (false, "无法合成点击") }
        let erased = canvas.state.lines.first(where: { $0.id == probe.id })?.points ?? []
        guard erased.count < before.count else { return (false, "橡皮擦一个点都没删掉") }

        guard canvas.undo() != nil else { return (false, "撤销没有生效") }
        guard canvas.state.lines.first(where: { $0.id == probe.id })?.points == before else {
            return (false, "撤销之后没有回到擦除前的点")
        }

        let label = canvas.redo()
        let after = canvas.state.lines.first(where: { $0.id == probe.id })?.points ?? []
        let passed = after == erased && label == "擦除"
        return (passed, passed
            ? "\(before.count) 点 → 擦掉 \(before.count - erased.count) 点 → 恢复「\(label ?? "")」后逐点回到擦除后"
            : "恢复「\(label ?? "无")」后 \(after.count) 点(应 \(erased.count)"
                + (after == erased ? "" : ",且点位不同") + ")")
    }

    /// One eraser click, undone.
    ///
    /// Compared point by point rather than by count: a restore that handed back
    /// the right number of markers in the wrong places would pass a count check,
    /// and the curve drawn from them would be different from the one the user had.
    private static func undoBringsBackAnErasedStroke() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas(),
              let line = probe.canvas.state.lines.first(where: { $0.id == probe.id }),
              line.points.count > 40 else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        let before = line.points

        canvas.tool = .eraser
        canvas.eraserRadius = 40
        guard click(at: before[before.count / 2], on: canvas) else { return (false, "无法合成点击") }

        let afterErase = canvas.state.lines.first(where: { $0.id == probe.id })?.points ?? []
        guard afterErase.count < before.count else { return (false, "橡皮擦一个点都没删掉") }

        let label = canvas.undo()
        let restored = canvas.state.lines.first(where: { $0.id == probe.id })?.points ?? []
        let passed = restored == before && label == "擦除"
        return (passed, passed
            ? "擦掉 \(before.count - afterErase.count) 点 → 撤销「\(label ?? "")」后 \(restored.count) 点逐点复原"
            : "撤销「\(label ?? "无")」后 \(restored.count) 点(应 \(before.count)"
                + (restored == before ? "" : ",且不是原来的点") + ")")
    }

    /// A drag is one undo step, not one per `mouseDragged`.
    ///
    /// This is the check the whole gesture-snapshot design exists for. The eraser
    /// mutates the model on every move — twelve here, one per pixel of travel in
    /// the real thing — so a canvas that committed at each of them would leave
    /// twelve entries behind, and the user's first 撤销 would bring back one
    /// twelfth of a stroke. The assertion has to be that *one* undo restores the
    /// whole thing, because after the fact the two designs are indistinguishable:
    /// both leave the stack non-empty and both name the last step 擦除.
    private static func oneDragIsOneUndoStep() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas(),
              let line = probe.canvas.state.lines.first(where: { $0.id == probe.id }),
              line.points.count > 80 else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        let before = line.points
        let from = before[before.count / 4]
        let to = before[before.count * 3 / 4]

        canvas.tool = .eraser
        canvas.eraserRadius = 40
        guard let down = dragEvent(canvas, .leftMouseDown, CGPoint(x: from.x, y: from.y)) else {
            return (false, "无法合成按下")
        }
        canvas.mouseDown(with: down)
        let steps = 12
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            guard let drag = dragEvent(canvas, .leftMouseDragged, p) else { return (false, "无法合成拖动") }
            canvas.mouseDragged(with: drag)
        }
        guard let up = dragEvent(canvas, .leftMouseUp, CGPoint(x: to.x, y: to.y)) else {
            return (false, "无法合成抬起")
        }
        canvas.mouseUp(with: up)

        let afterStroke = canvas.state.lines.first(where: { $0.id == probe.id })?.points ?? []
        let removed = before.count - afterStroke.count
        guard removed > 1 else { return (false, "这一拖只删掉 \(removed) 个点,看不出合并") }

        let label = canvas.undo()
        let once = canvas.state.lines.first(where: { $0.id == probe.id })?.points ?? []
        let passed = once == before && label == "擦除"
        return (passed, passed
            ? "\(steps) 次 mouseDragged 删掉 \(removed) 点,一次撤销全部复原"
            : "撤销一次后还有 \(before.count - once.count) 点没回来(应 0),标签「\(label ?? "无")」")
    }

    /// A 区域取点 pass, undone.
    ///
    /// The pass *appends* — an area scan adds to whatever the curve already has —
    /// so this is the case the eraser's check cannot stand in for: the state
    /// grows, and the undo has to take the growth back rather than restore a
    /// deletion.
    private static func undoTakesBackAPointTakingPass() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas(),
              let line = probe.canvas.state.lines.first(where: { $0.id == probe.id }),
              let buffer = probe.canvas.buffer else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        let before = line.points

        // The left half, at a spacing that certainly finds pixels: the fixture's
        // own pass covered the whole image, so any part of it has curve in it.
        let corner = CGPoint(x: Double(buffer.width) / 2, y: Double(buffer.height) - 2)
        canvas.tool = .gridDigitize
        guard let down = dragEvent(canvas, .leftMouseDown, CGPoint(x: 2, y: 2)),
              let drag = dragEvent(canvas, .leftMouseDragged, corner),
              let up = dragEvent(canvas, .leftMouseUp, corner) else { return (false, "无法合成框选") }
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: drag)
        canvas.mouseUp(with: up)

        let after = canvas.state.lines.first(where: { $0.id == probe.id })?.points ?? []
        guard after.count > before.count else {
            return (false, "第二次框选没有取到点(\(before.count) → \(after.count))")
        }

        let label = canvas.undo()
        let restored = canvas.state.lines.first(where: { $0.id == probe.id })?.points ?? []
        let passed = restored == before && label == "区域取点"
        return (passed, passed
            ? "再取 \(after.count - before.count) 点 → 撤销「\(label ?? "")」后回到 \(restored.count) 点"
            : "撤销「\(label ?? "无")」后 \(restored.count) 点(应 \(before.count))")
    }

    /// Undoing a colour pick has to take the mask with it.
    ///
    /// The masks are a cache keyed by curve and built from the curve's colour, so
    /// they are exactly the thing a restore can leave stale — and a stale one is
    /// silent: the curve would still be digitised through the colour it no longer
    /// has, and every point taken would be right for a state that is no longer on
    /// screen. This is why the check looks at the mask rather than at the colour.
    private static func undoKeepsTheMaskInStepWithTheColour() -> (passed: Bool, detail: String) {
        let chart = SyntheticChart.render()
        guard let cg = SampleChartWriter.makeCGImage(from: chart.buffer) else { return (false, "无法生成图") }
        let frame = NSRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        let canvas = CanvasView(frame: frame)
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        canvas.load(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        canvas.layoutSubtreeIfNeeded()

        canvas.addLine()
        guard canvas.activeMask == nil else { return (false, "还没取色就有了掩膜") }

        canvas.tool = .pickLineColor
        guard click(at: chart.curvePixels[chart.curvePixels.count / 2], on: canvas),
              canvas.activeMask != nil else { return (false, "取色之后仍然没有掩膜") }

        let label = canvas.undo()
        let goneAgain = canvas.activeMask == nil
        let redone = canvas.redo()
        let backAgain = canvas.activeMask != nil

        let passed = goneAgain && backAgain && label == "取曲线颜色" && redone == "取曲线颜色"
        return (passed, passed
            ? "撤销「\(label ?? "")」后掩膜清掉 → 重做后回来"
            : "撤销后掩膜\(goneAgain ? "已清" : "还在") · 重做后掩膜\(backAgain ? "在" : "不在")"
                + " · 标签「\(label ?? "无")」/「\(redone ?? "无")」")
    }

    /// Opening a different picture forgets the history.
    ///
    /// The snapshots carry pixel coordinates, which mean nothing on another
    /// chart: restoring one would put the old curve's points onto the new
    /// picture. Clearing is the only honest answer, and it has to clear both
    /// directions — a redo onto the previous image is the same mistake.
    private static func loadingAnImageForgetsTheHistory() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas() else { return (false, "无法构建画布") }
        guard probe.canvas.canUndo else { return (false, "取完点却没有历史可撤") }
        probe.canvas.undo()
        guard probe.canvas.canRedo else { return (false, "撤销之后没有重做分支") }

        guard let cg = SampleChartWriter.makeCGImage(from: SyntheticChart.render().buffer) else {
            return (false, "无法生成第二张图")
        }
        probe.canvas.load(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))

        let passed = !probe.canvas.canUndo && !probe.canvas.canRedo
        return (passed, passed
            ? "换图前可撤可重做,换图后两侧都清空"
            : "换图后仍可撤销=\(probe.canvas.canUndo) 重做=\(probe.canvas.canRedo)")
    }

    // MARK: - 网格方向与偏移 (grid axis & phase)

    /// Both directions, swept once each through the real canvas.
    ///
    /// Shared by the two checks below: everything about them is the same except
    /// what is asserted afterwards.
    private static func sweepWithGrid(_ canvas: CanvasView, line id: UUID,
                                      width: Int, height: Int) -> [PixelPoint]? {
        canvas.clearPoints(of: id)
        canvas.tool = .gridDigitize
        canvas.selectLine(id: id)
        guard let down = dragEvent(canvas, .leftMouseDown, CGPoint(x: 2, y: 2)),
              let drag = dragEvent(canvas, .leftMouseDragged,
                                   CGPoint(x: Double(width - 2), y: Double(height - 2))),
              let up = dragEvent(canvas, .leftMouseUp,
                                 CGPoint(x: Double(width - 2), y: Double(height - 2)))
        else { return nil }
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: drag)
        canvas.mouseUp(with: up)
        let points = canvas.state.lines.first(where: { $0.id == id })?.points
        return (points?.isEmpty ?? true) ? nil : points
    }

    /// Turning the grid a quarter turn actually changes what gets scanned.
    ///
    /// Read off the coordinates rather than the stored setting. An X grid's
    /// points sit on a **column** lattice and have arbitrary rows; a Y grid's are
    /// the other way round — so which of the two coordinates is on the lattice,
    /// and which is a run mean ending in .5, says which sweep really ran. A menu
    /// item wired to the setting but not to the digitizer would satisfy a check on
    /// the setting and change nothing on screen.
    private static func gridAxisReachesTheDigitizer() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas(), let buffer = probe.canvas.buffer else {
            return (false, "无法构建画布")
        }
        let canvas = probe.canvas
        let dx = canvas.state.gridSpacing
        let width = buffer.width, height = buffer.height

        canvas.setGridAxis(.x)
        guard let byColumn = sweepWithGrid(canvas, line: probe.id, width: width, height: height)
        else { return (false, "X 网格没取到点") }
        canvas.setGridAxis(.y)
        guard let byRow = sweepWithGrid(canvas, line: probe.id, width: width, height: height)
        else { return (false, "Y 网格没取到点") }

        let columnsOnLattice = byColumn.allSatisfy { Int($0.x) % dx == 0 }
        let rowsOnLattice = byRow.allSatisfy { Int($0.y) % dx == 0 }
        // And the other coordinate must *not* be on a lattice — otherwise both
        // sweeps would be producing squares, which no scan line does.
        let columnRunMeans = byColumn.contains { $0.y != $0.y.rounded() }
        let rowRunMeans = byRow.contains { $0.x != $0.x.rounded() }
        let passed = columnsOnLattice && rowsOnLattice && columnRunMeans && rowRunMeans
        return (passed, passed
            ? "X 网格 \(byColumn.count) 点的列都在 \(dx) 的整数倍上;"
                + "Y 网格 \(byRow.count) 点的行都在 \(dx) 的整数倍上,游程均值落在半像素"
            : "X 落列=\(columnsOnLattice) Y 落行=\(rowsOnLattice)"
                + " · X 游程均值=\(columnRunMeans) Y 游程均值=\(rowRunMeans)")
    }

    /// 「对齐到坐标轴起点」puts a scan line on the anchor's own column.
    ///
    /// The anchors are deliberately placed off any multiple of the spacing, so an
    /// implementation that ignored the alignment and left the phase at zero cannot
    /// pass by luck.
    private static func aligningTheGridPutsTheLinesOnTheAnchor() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas(), let buffer = probe.canvas.buffer else {
            return (false, "无法构建画布")
        }
        let canvas = probe.canvas
        let anchors = CalibrationAnchors(xStart: PixelPoint(x: 46, y: 560),
                                         xEnd: PixelPoint(x: 840, y: 560),
                                         yStart: PixelPoint(x: 46, y: 560),
                                         yEnd: PixelPoint(x: 46, y: 60))
        canvas.applyCalibration(anchors: anchors,
                                xStartValue: 0, xEndValue: 10,
                                yStartValue: 0, yEndValue: 5,
                                xIsLogarithmic: false, yIsLogarithmic: false)
        let dx = canvas.state.gridSpacing
        canvas.setGridAxis(.x)
        canvas.alignGrid(toPixel: anchors.xStart.x, spacing: dx)

        guard let points = sweepWithGrid(canvas, line: probe.id,
                                         width: buffer.width, height: buffer.height)
        else { return (false, "对齐后没取到点") }
        let phase = canvas.state.areaDigitizingGrid.phase
        let onTheLattice = points.allSatisfy { Int($0.x) % dx == phase }
        let moved = phase != 0
        let passed = onTheLattice && moved
        return (passed, passed
            ? "锚点列 \(Int(anchors.xStart.x)) → 相位 \(phase);"
                + "\(points.count) 个点全部落在 \(phase)+\(dx)k 上"
            : "相位 \(phase)(不该为 0)· 全部落线=\(onTheLattice)")
    }

    // MARK: - 两个「用来看」的视图 (FR-1.3 / FR-7.1)

    /// Hiding the picture is a way of looking at the work, not a change to it.
    ///
    /// Three things have to hold, and each is a way the switch could have been
    /// written wrongly: the document must not move (the flag is view state, so it
    /// is in neither the project file nor the undo history), the bitmap the tools
    /// sample must still be there, and a tool must still work while nothing is
    /// drawn — because the entire value of the switch is judging the points with
    /// the curve no longer underneath them.
    private static func hidingTheImageTakesNothingAway() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas() else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        let before = canvas.state
        let pointsBefore = canvas.state.lines.first(where: { $0.id == probe.id })?.points.count ?? 0
        let hadMask = canvas.activeMask != nil

        canvas.showsImage = false
        let stateUnchanged = canvas.state == before
        let bufferKept = canvas.buffer?.width == probe.imageWidth
        let maskKept = canvas.activeMask != nil

        // 手工取点 needs no mask — it samples the picture directly — so a click
        // while the image is hidden must still land on the curve.
        canvas.tool = .capture
        canvas.selectLine(id: probe.id)
        let clicked = click(at: PixelPoint(x: 450, y: 320), on: canvas)
        let pointsAfter = canvas.state.lines.first(where: { $0.id == probe.id })?.points.count ?? 0
        let added = pointsAfter == pointsBefore + 1

        canvas.showsImage = true
        let restored = canvas.showsImage

        let passed = hadMask && stateUnchanged && bufferKept && maskKept && clicked && added && restored
        return (passed, passed
            ? "隐藏时文档逐项未变 · 位图与掩膜都在 · 点击仍取到点(\(pointsBefore)→\(pointsAfter)) · 恢复显示正常"
            : "原本有掩膜=\(hadMask) 文档未变=\(stateUnchanged) 位图在=\(bufferKept)"
                + " 掩膜在=\(maskKept) 点击=\(clicked) 取到点=\(added)(\(pointsBefore)→\(pointsAfter))"
                + " 恢复=\(restored)")
    }

    /// What the data view adds that the canvas cannot — FR-7.1, asserted as
    /// *usefulness* rather than as "a window opened".
    ///
    /// The claim being tested is the reason the feature exists: a wrong order is
    /// invisible on the scanned chart (the marker dots sit on the curve either
    /// way) and obvious in data coordinates, where it becomes a polyline that
    /// doubles back and forth. The shape is built by hand because the argument
    /// needs one that is multi-valued in x — a chart that happened to be
    /// single-valued would make the check pass for the wrong reason.
    private static func theDataViewShowsAnOrderTheCanvasCannot() -> (passed: Bool, detail: String) {
        let width = 80, height = 140
        let curve: (Double) -> Double = { 40 + 20 * sin($0 / 9) }
        var bits = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width where abs(Double(x) - curve(Double(y))) <= 2 {
                bits[y * width + x] = true
            }
        }
        let mask = ForegroundMask(width: width, height: height, bits: bits)
        let rect = PixelRect(x0: 0, y0: 0, x1: width - 1, y1: height - 1)
        let calibration = CalibrationMap(
            x: AxisCalibration(pixelMin: 20, valueMin: 0, pixelMax: 60, valueMax: 10),
            y: AxisCalibration(pixelMin: 139, valueMin: 0, pixelMax: 0, valueMax: 140))

        /// Length of the polyline the data view would draw.
        func dataPathLength(_ points: [PixelPoint]) -> Double {
            let data = points.compactMap { try? calibration.data(fromPixel: $0) }
            return zip(data, data.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }

        let byColumn = AreaDigitizer.digitize(mask: mask, rect: rect, dx: 10, axis: .x)
        let byRow = AreaDigitizer.digitize(mask: mask, rect: rect, dx: 10, axis: .y)
        guard byColumn.count > 4, byRow.count > 4 else { return (false, "固定装置没取到点") }

        let columnLength = dataPathLength(byColumn)
        let rowLength = dataPathLength(byRow)
        let ratio = rowLength > 0 ? columnLength / rowLength : 0
        let passed = ratio > 2
        return (passed, passed
            ? "同一批点画在数据坐标里:列序折线 \(Int(columnLength)) 长,行序 \(Int(rowLength)) 长,差 "
                + String(format: "%.1f", ratio) + " 倍 —— 取歪的顺序一眼能看出来"
            : "列序 \(Int(columnLength)) 行序 \(Int(rowLength)),差 \(String(format: "%.2f", ratio)) 倍,不够明显")
    }

    /// The labels a reader gets. The values behind them are binary doubles, so
    /// anything that printed them raw would label a tick "0.6000000000000001".
    private static func theDataPlotLabelsAreReadable() -> (passed: Bool, detail: String) {
        let cases: [(Double, String)] = [
            (0, "0"),
            (0.2 + 0.2 + 0.2, "0.6"),
            (1, "1"),
            (1000, "1000"),
            (-2.5, "-2.5"),
            (0.25, "0.25"),
        ]
        var wrong: [String] = []
        for (value, want) in cases where DataPlotView.number(value) != want {
            wrong.append("\(value) → \(DataPlotView.number(value))(应为 \(want))")
        }
        // Extreme magnitudes may go scientific; they must not go unreadable.
        for value in [1e-7, 5e8] where DataPlotView.number(value).isEmpty {
            wrong.append("\(value) 没有标签")
        }
        let passed = wrong.isEmpty
        return (passed, passed
            ? "6 个常见值都印成人的写法(含 0.2+0.2+0.2 → 0.6)"
            : wrong.joined(separator: " · "))
    }

    // MARK: - 换文件前的确认 (the replace guard)

    /// A chart image on disk, so the open path can be driven for real.
    private static func writeChartImage(named name: String) -> URL? {
        guard let cg = SampleChartWriter.makeCGImage(from: SyntheticChart.render().buffer),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        return (try? png.write(to: url)) != nil ? url : nil
    }

    /// Opening another file must not throw away an unsaved document.
    ///
    /// Driven through the real `openDocument(at:)` — the point that every way in
    /// passes through (`⌘O`, a double-click in the Finder, a drop on the icon,
    /// and the file handed over at launch) — with the alert replaced by a stub
    /// answer. The stub is not a convenience: an `NSAlert.runModal()` cannot be
    /// driven head-lessly at all, so the cancel branch is unreachable without it,
    /// and a missing call site is exactly the kind of bug that leaves no trace.
    ///
    /// Three answers in one pass:
    ///
    ///   · nothing edited yet → nobody is asked, because there is nothing to lose
    ///   · 取消               → the document survives, down to the calibration
    ///   · 不保存             → the replacement happens
    private static func openingAFileAsksBeforeDiscardingTheDocument() -> (passed: Bool, detail: String) {
        guard let first = writeChartImage(named: "gd-selftest-open-a.png"),
              let second = writeChartImage(named: "gd-selftest-open-b.png") else {
            return (false, "写不出测试图片")
        }
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let delegate = AppDelegate()
        // The same order  uses. It matters:
        // `refreshUI` names the undo action in its menu items, so building the
        // window first would announce a state change into menu items that do not
        // exist yet.
        delegate.buildMenu()
        delegate.buildWindow()
        guard let canvas = delegate.canvas else { return (false, "画布没建出来") }

        var asked = 0
        var answer = NSApplication.ModalResponse.alertThirdButtonReturn   // 取消
        delegate.unsavedChangesPrompt = {
            asked += 1
            return answer
        }

        delegate.openDocument(at: first)
        let askedWhenClean = asked
        guard canvas.imageName == first.lastPathComponent else {
            return (false, "第一张图没打开(画布上是 \(canvas.imageName ?? "空"))")
        }

        // An edit that exists only in memory — the thing worth protecting.
        canvas.applyCalibration(anchors: CalibrationAnchors(
                                    xStart: PixelPoint(x: 40, y: 300),
                                    xEnd: PixelPoint(x: 400, y: 300),
                                    yStart: PixelPoint(x: 40, y: 300),
                                    yEnd: PixelPoint(x: 40, y: 40)),
                                xStartValue: 0, xEndValue: 10,
                                yStartValue: 0, yEndValue: 5,
                                xIsLogarithmic: false, yIsLogarithmic: false)
        guard canvas.hasUnsavedChanges else { return (false, "编辑没有把文档标脏") }
        let calibration = canvas.state.calibration

        delegate.openDocument(at: second)
        let askedOnCancel = asked - askedWhenClean
        let survived = canvas.imageName == first.lastPathComponent
            && canvas.state.calibration == calibration
            && canvas.hasUnsavedChanges

        answer = .alertSecondButtonReturn   // 不保存
        delegate.openDocument(at: second)
        let askedOnDiscard = asked - askedWhenClean - askedOnCancel
        let replaced = canvas.imageName == second.lastPathComponent
            && canvas.state.calibration == nil
            && !canvas.hasUnsavedChanges

        let passed = askedWhenClean == 0 && askedOnCancel == 1 && askedOnDiscard == 1
            && survived && replaced
        return (passed, passed
            ? "未编辑时不问 · 取消后文档与标定原样保留 · 选不保存才换成新图"
            : "未编辑却问了 \(askedWhenClean) 次 · 取消时问了 \(askedOnCancel) 次 · 原文档保留=\(survived)"
                + " · 不保存时问了 \(askedOnDiscard) 次 · 已替换=\(replaced)")
    }

    // MARK: - 导出小数分隔符 (FR-11)

    /// The decimal separator, checked through the bytes an export actually
    /// produces rather than through the setting.
    ///
    /// The preference has no other observable effect: nothing on screen moves
    /// when it changes, and the save panel that would show the file needs a
    /// person to answer it. So the check drives the real menu path — the real
    /// `setDecimalSeparator`, which is what the menu item calls — and then reads
    /// `exportPayload` / `clipboardText`, which are the calls the save panel and
    /// the pasteboard make. What is being verified is the *wiring*: a setting
    /// that reaches the menu and not the exporter looks exactly like this one
    /// working, right up to the moment a colleague opens the file.
    ///
    /// Run against a store that only lives in memory. The selftest is a real run
    /// of the real binary, so writing the preference through
    /// `UserDefaults.standard` here would leave it changed for whoever ran it.
    ///
    /// What that trades away, stated plainly: this no longer proves the setting
    /// survives a relaunch. That property is `ExportPreferenceStore.userDefaults`
    /// — two closures calling `UserDefaults.standard` — and it is not asserted
    /// anywhere, because asserting it means writing a real preference on the
    /// machine that ran the test. A first cut of this check used
    /// `UserDefaults(suiteName:)` and `removePersistentDomain` to have both; it
    /// left a 42-byte plist in the user's Preferences folder, which was noticed
    /// by looking rather than by reasoning.
    private static func theDecimalSeparatorReachesTheExportedBytes() -> (passed: Bool, detail: String) {
        let delegate = AppDelegate()
        delegate.exportPreferenceStore = .inMemory()
        delegate.buildMenu()
        delegate.buildWindow()
        guard let canvas = delegate.canvas else { return (false, "画布没建出来") }

        // A curve whose values really do have fractions in them, loaded as a
        // project so the canvas carries both a calibration and points. Built
        // rather than scanned: what is under test is the spelling of the numbers,
        // so the numbers want to be known exactly.
        let chart = SyntheticChart.render()
        guard let cg = SampleChartWriter.makeCGImage(from: chart.buffer),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return (false, "造不出测试图") }
        var state = ProjectState(calibration: CalibrationMap(
            x: AxisCalibration(pixelMin: 100, valueMin: 0, pixelMax: 900, valueMax: 10),
            y: AxisCalibration(pixelMin: 600, valueMin: 0, pixelMax: 100, valueMax: 5)))
        // (250,480) -> (1.875, 1.2); (500,350) -> (5, 2.5).
        state.append(points: [PixelPoint(x: 250, y: 480), PixelPoint(x: 500, y: 350)],
                     usingDefaultColor: RGB8(r: 200, g: 40, b: 40))
        let document = ProjectDocument(
            header: ProjectHeader(image: ProjectImageInfo(fileName: "separator.png",
                                                          pixelWidth: chart.buffer.width,
                                                          pixelHeight: chart.buffer.height),
                                  state: state),
            imageData: png)
        guard canvas.load(project: document) else { return (false, "项目载不进画布") }

        // The menu itself. Two entries, each carrying the setting it stands for:
        // a pair wired to the same one would look right and never change a byte.
        var separatorItems: [NSMenuItem] = []
        func find(_ menu: NSMenu) {
            for item in menu.items {
                if item.submenu?.title == "Decimal Separator" {
                    separatorItems = item.submenu?.items ?? []
                    return
                }
                if let sub = item.submenu { find(sub) }
            }
        }
        if let main = NSApp.mainMenu { find(main) }
        let offered = Set(separatorItems.compactMap { $0.representedObject as? String })
        let menuOK = separatorItems.count == DecimalSeparator.allCases.count
            && offered == Set(DecimalSeparator.allCases.map(\.rawValue))

        func tick(of separator: DecimalSeparator) -> NSControl.StateValue? {
            separatorItems.first { $0.representedObject as? String == separator.rawValue }?.state
        }

        // 逗号 —— 数值写成 1,5,CSV 的列必须改用分号。
        delegate.setDecimalSeparator(.comma)
        // The setter and the getter have to agree on the key. A second delegate
        // reading the same store is the cheapest way to say so, and the failure it
        // catches is a real one: a setter writing one key while the getter reads
        // another looks exactly like this feature working, right up to the export.
        let remembered = AppDelegate()
        remembered.exportPreferenceStore = delegate.exportPreferenceStore
        let roundTrips = remembered.exportDecimalSeparator == .comma

        let commaCSV = (try? delegate.exportPayload(format: .csv))
            .flatMap { String(data: $0, encoding: .utf8) }
        let commaTSV = try? delegate.clipboardText()
        let expectedCommaCSV = "x;y\n1,875000;1,200000\n5,000000;2,500000\n"
        let commaOK = commaCSV == expectedCommaCSV && commaTSV == "x\ty\n1,875000\t1,200000\n5,000000\t2,500000\n"
        let commaTick = tick(of: .comma) == .on && tick(of: .dot) == .off

        // …and the default, which is the backward-compatibility promise: every
        // caller that existed before this feature passed no separator at all.
        delegate.setDecimalSeparator(.dot)
        let dotCSV = (try? delegate.exportPayload(format: .csv))
            .flatMap { String(data: $0, encoding: .utf8) }
        let dotOK = dotCSV == "x,y\n1.875000,1.200000\n5.000000,2.500000\n"
            && (try? delegate.clipboardText()) == "x\ty\n1.875000\t1.200000\n5.000000\t2.500000\n"
            && tick(of: .dot) == .on && tick(of: .comma) == .off

        // The machine formats ignore it entirely — their grammars are fixed, and
        // `x="1,5"` is not a number to an XML parser. Byte-for-byte, because
        // "nearly the same file" is the failure mode that would matter.
        let dotXML = try? delegate.exportPayload(format: .xml)
        delegate.setDecimalSeparator(.comma)
        let commaXML = try? delegate.exportPayload(format: .xml)
        delegate.setDecimalSeparator(.dot)
        let xmlSame = dotXML != nil && dotXML == commaXML

        let passed = menuOK && roundTrips && commaOK && commaTick && dotOK && xmlSame
        return (passed, passed
            ? "逗号:1,875000 · CSV 用分号 · 剪贴板同步 · 读写键一致 · 句点下与旧文件逐字节相同 · XML 不受影响"
            : "菜单=\(menuOK)(\(separatorItems.count) 项) 读写键一致=\(roundTrips)"
                + " 逗号输出=\(commaOK)[\(commaCSV ?? "nil")] 勾=\(commaTick)"
                + " 句点输出=\(dotOK)[\(dotCSV ?? "nil")] XML不变=\(xmlSame)")
    }

    // MARK: - 多坐标系 (FR-13)

    /// Two panels on one image, each with its own curve.
    ///
    /// What is under test is *which* mapping each curve's numbers come from, and
    /// the only way to see that is to look at the bytes an export produced —
    /// exactly the reason `exportPayload` exists. The two curves sit at the same
    /// fraction along their own panel's axes, so a shared mapping would give both
    /// the same numbers and the check would fail on the numbers rather than on a
    /// description of them.
    private static func twoCoordinateSystemsConvertTheirOwnCurves()
        -> (passed: Bool, detail: String) {
        let delegate = AppDelegate()
        delegate.buildMenu()
        delegate.buildWindow()
        guard let canvas = delegate.canvas else { return (false, "画布没建出来") }

        // Panel A spans 0–10, panel B spans 0–1000. Both curves sit halfway along
        // their own axes, so the right answer is 5 and 500 — and 5 and 5 would
        // mean one mapping was used for both.
        let panelA = CalibrationMap.linear(xMin: 0, yMin: 0, xMax: 10, yMax: 10,
                                           pixelXMin: 100, pixelYMin: 700,
                                           pixelXMax: 500, pixelYMax: 300)
        let panelB = CalibrationMap.linear(xMin: 0, yMin: 0, xMax: 1000, yMax: 1000,
                                           pixelXMin: 600, pixelYMin: 700,
                                           pixelXMax: 1000, pixelYMax: 300)
        var state = ProjectState()
        let aID = state.addLine(name: "a", color: RGB8(r: 200, g: 40, b: 40))
        state.append(points: [PixelPoint(x: 300, y: 500)],
                     usingDefaultColor: RGB8(r: 0, g: 0, b: 0))
        state.installCalibration(panelA)
        state.addCoordinateSystem()
        let secondSystem = state.activeSystem?.id
        let bID = state.addLine(name: "b", color: RGB8(r: 40, g: 60, b: 200))
        state.append(points: [PixelPoint(x: 800, y: 500)],
                     usingDefaultColor: RGB8(r: 0, g: 0, b: 0))
        state.installCalibration(panelB)
        guard state.systems.count == 2, let secondSystem else {
            return (false, "建不出两套坐标系(只有 \(state.systems.count) 套)")
        }

        let chart = SyntheticChart.render()
        guard let cg = SampleChartWriter.makeCGImage(from: chart.buffer),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return (false, "造不出测试图") }
        let document = ProjectDocument(
            header: ProjectHeader(image: ProjectImageInfo(fileName: "two-panels.png",
                                                          pixelWidth: chart.buffer.width,
                                                          pixelHeight: chart.buffer.height),
                                  state: state),
            imageData: png)
        guard canvas.load(project: document) else { return (false, "项目载不进画布") }
        guard canvas.state.systems.count == 2 else {
            return (false, "载入后只剩 \(canvas.state.systems.count) 套坐标系")
        }

        // --- 导出:每条曲线按自己的坐标系换算 -------------------------------
        let csv = (try? delegate.exportPayload(format: .csv))
            .flatMap { String(data: $0, encoding: .utf8) }
        let expected = "x1,y1,x2,y2\n5.000000,5.000000,500.000000,500.000000\n"
        let exportOK = csv == expected

        // --- 菜单:两套都列出来,勾在当前那套 --------------------------------
        var systemItems: [NSMenuItem] = []
        func find(_ menu: NSMenu) {
            for item in menu.items {
                if item.submenu?.title == "Active Coordinate System" {
                    systemItems = item.submenu?.items ?? []
                    return
                }
                if let sub = item.submenu { find(sub) }
            }
        }
        if let main = NSApp.mainMenu { find(main) }
        let menuOK = systemItems.count == 2
            && systemItems.filter { $0.state == .on }.count == 1
        // The tick has to be on the one that is active, not merely on one of them.
        let tickOnActive = systemItems.first { $0.state == .on }?.representedObject as? String
            == canvas.state.activeSystem?.id.uuidString

        // --- 行为约定之一:选中曲线即切换活跃坐标系 -------------------------
        canvas.selectLine(id: aID)
        let bCurve = canvas.state.lines.first { $0.id == bID }
        let followsSelection = canvas.state.activeSystem?.id == state.systems[0].id
            && canvas.state.calibration == panelA
            && (bCurve.map { canvas.state.calibration(for: $0) == panelB } ?? false)

        // --- 行为约定之三:挂着曲线的坐标系删不掉 ---------------------------
        let firstSystem = state.systems[0].id
        let refused = canvas.removeCoordinateSystem(id: firstSystem) == false
            && canvas.state.systems.count == 2
        if case .ownsCurves(let count)? = canvas.refusalForRemovingCoordinateSystem(id: firstSystem) {
            if count != 1 { return (false, "拒绝理由里的曲线数不对:\(count)") }
        } else {
            return (false, "删掉挂着一两条曲线的坐标系没有被拒绝")
        }
        // 挪走之后就能删了。
        canvas.selectLine(id: aID)
        let moved = canvas.assignActiveLine(toSystem: secondSystem)
        let deleted = moved && canvas.removeCoordinateSystem(id: firstSystem)
        let oneLeft = canvas.state.systems.count == 1

        // --- 侧栏:resolver 给出即权威,不借活跃坐标系的映射 -------------------
        // A curve whose own system has no calibration, shown in a panel whose
        // default mapping is a *different*, calibrated one. Reading the default's
        // numbers for this curve would be the neighbouring-panel failure the
        // exporter refuses — so the panel must show pixels and say 「未标定」.
        var sideState = ProjectState()
        let orphanID = sideState.addLine(name: "orphan", color: RGB8(r: 1, g: 2, b: 3))
        sideState.append(points: [PixelPoint(x: 300, y: 500)],
                         usingDefaultColor: RGB8(r: 0, g: 0, b: 0))
        sideState.addCoordinateSystem()
        // Calibrates the new, active system — not the one the curve lives in.
        sideState.installCalibration(panelA)
        let side = SidebarView(frame: NSRect(x: 0, y: 0, width: 264, height: 700))
        side.update(lines: sideState.lines,
                    calibration: sideState.calibration,
                    activeID: orphanID,
                    resolvingWith: { sideState.calibration(for: $0) })
        side.layoutSubtreeIfNeeded()
        let sidePointTable = descendants(of: side).compactMap { $0 as? NSTableView }
            .first { $0.tableColumns.map(\.identifier.rawValue) == ["index", "x", "y"] }
        let xCell = sidePointTable.flatMap { table in
            side.tableView(table, viewFor: table.tableColumns[1], row: 0)
        }
        let xText = xCell.flatMap {
            descendants(of: $0).compactMap { $0 as? NSTextField }.first?.stringValue
        }
        let sideHeading = descendants(of: side).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("数据点 ·") }?.stringValue
        // The pixel is 300; panelA would read that same pixel as 5 — showing 5
        // here would be the other panel's units wearing this curve's points.
        let sidebarAuthoritative = xText == "300.000000"
            && (sideHeading?.contains("未标定") ?? false)

        let passed = exportOK && menuOK && tickOnActive && followsSelection
            && refused && deleted && oneLeft && sidebarAuthoritative
        return (passed, passed
            ? "两套坐标系各按自己换算(a=5,b=500)· 菜单列两套且勾在活跃那套"
                + " · 选中曲线即切换 · 挂曲线的删不掉、挪走后可删 · 侧栏不借别套映射"
            : "导出=\(exportOK)[\(csv ?? "nil")] 菜单=\(menuOK)(\(systemItems.count) 项)"
                + " 勾在活跃=\(tickOnActive) 跟随选中=\(followsSelection)"
                + " 拒绝删除=\(refused) 挪走=\(moved) 删掉=\(deleted) 剩一套=\(oneLeft)"
                + " 侧栏权威=\(sidebarAuthoritative)[x=\(xText ?? "nil") 头=\(sideHeading ?? "nil")]")
    }

    /// Adding a coordinate system must arm the calibration tool, whatever tool
    /// was in hand. The user reported the hole from life: they were mid-取点,
    /// added a system for the next panel, and the app left them in 取点 — so
    /// the next clicks would have taken points against a system with no axes,
    /// producing numbers with no meaning. Driven on the real canvas with the
    /// tool deliberately set to a digitising one first.
    private static func addingASystemArmsCalibration() -> (passed: Bool, detail: String) {
        let delegate = AppDelegate()
        delegate.buildMenu()
        delegate.buildWindow()
        guard let canvas = delegate.canvas else { return (false, "画布没建出来") }

        canvas.tool = .traceDigitize
        let before = canvas.tool
        canvas.addCoordinateSystem()
        let armed = canvas.tool == .setScale
        let systemsGrew = canvas.state.systems.count == 2
        let passed = before == .traceDigitize && armed && systemsGrew
        return (passed, passed
            ? "取点中新增坐标系 → 工具切到标定,系统数 1→2"
            : "before=\(before) after=\(canvas.tool) 系统数=\(canvas.state.systems.count)")
    }

    // MARK: - 符号匹配 (scatter symbols)

    /// A canvas with a synthetic scatter plot on it and its symbols' colour
    /// sampled — the state 符号匹配 starts from.
    private static func scatterCanvas(count: Int = 30, markerDiameter: Int = 11,
                                      legendSwatch: Bool = false)
        -> (canvas: CanvasView, id: UUID, chart: SyntheticChart.ScatterChart)? {
        let chart = SyntheticChart.renderScatter(count: count, markerDiameter: markerDiameter,
                                                legendSwatch: legendSwatch)
        guard let cg = SampleChartWriter.makeCGImage(from: chart.buffer) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let frame = NSRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        let canvas = CanvasView(frame: frame)
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        canvas.load(image: image)
        canvas.layoutSubtreeIfNeeded()

        // Sample the colour off the first symbol, through the real handler.
        canvas.tool = .pickLineColor
        canvas.addLine()
        guard let id = canvas.state.activeLineID,
              let first = chart.markerCentres.first,
              let pick = dragEvent(canvas, .leftMouseDown, CGPoint(x: first.x, y: first.y))
        else { return nil }
        canvas.mouseDown(with: pick)
        guard canvas.state.lines.first(where: { $0.id == id })?.lineColor != nil else { return nil }
        return (canvas, id, chart)
    }

    /// The whole tool, through the mouse handlers, plus the three rules that keep
    /// the preview honest.
    ///
    /// The preview is a picture, so what is asserted is the set it is drawn from:
    /// that entering the tool computes it, that the diameter knob re-runs it (a
    /// knob that only affected the *next* press would turn adjusting it into
    /// guess-and-check), and that leaving the tool drops it — a preview left
    /// behind would be drawn against a picture edited in the meantime, and rings
    /// computed from a colour the curve no longer has look exactly like good ones.
    ///
    /// And that one match is **one** undo step. The tool mutates the state inside
    /// the press-and-release gesture, so it must not also record a step of its
    /// own: doing both leaves the user needing two ⌘Z presses, with the first
    /// appearing to work.
    private static func symbolMatchingTakesEverySymbol() -> (passed: Bool, detail: String) {
        guard let probe = scatterCanvas() else { return (false, "无法构建散点画布") }
        let canvas = probe.canvas
        canvas.selectLine(id: probe.id)

        canvas.tool = .symbolMatch
        let onEntry = canvas.symbolPreview?.points.count ?? -1

        canvas.setValue(3, of: .markerDiameter)
        let whenTooSmall = canvas.symbolPreview?.points.count ?? -1
        canvas.setValue(Double(probe.chart.markerDiameter), of: .markerDiameter)
        let whenRight = canvas.symbolPreview?.points.count ?? -1

        canvas.tool = .browse
        let droppedOnLeaving = canvas.symbolPreview == nil
        canvas.tool = .symbolMatch

        // Anywhere on the canvas: the search covers the whole picture.
        guard click(at: PixelPoint(x: 4, y: 4), on: canvas),
              let points = canvas.state.lines.first(where: { $0.id == probe.id })?.points else {
            return (false, "点不下去")
        }
        let expected = probe.chart.markerCentres.count
        var worst = 0.0
        for centre in probe.chart.markerCentres {
            worst = max(worst, points.map { hypot($0.x - centre.x, $0.y - centre.y) }.min() ?? .infinity)
        }
        // Matching again must not double the curve. The search covers the whole
        // picture, so an implementation that *appended* would give sixty points on
        // the second press — and the count would look like "it found twice as
        // many", which is exactly how a plausible-looking wrong answer reads.
        var twice = 0
        if click(at: PixelPoint(x: 8, y: 8), on: canvas) {
            twice = canvas.state.lines.first(where: { $0.id == probe.id })?.points.count ?? -1
        } else {
            twice = -1
        }

        let label = canvas.undoLabel
        let undone = canvas.undo()
        let backToNothing = canvas.state.lines.first(where: { $0.id == probe.id })?.points.isEmpty == true
        // The step *under* the one just taken must not be the same action again:
        // a tool that records its own step as well as letting the gesture record
        // one files 「符号匹配」twice, and the user needs two ⌘Z presses where the
        // first already looks like it worked. Asserted on the label rather than on
        // "the stack is empty", because the curve was created and given a colour
        // first and those are steps of their own.
        let noSecondHelping = canvas.undoLabel != "符号匹配"

        let passed = onEntry == expected && whenTooSmall == 0 && whenRight == expected
            && droppedOnLeaving && points.count == expected && worst <= 0.5
            && twice == expected && label == "符号匹配" && undone == "符号匹配"
            && backToNothing && noSecondHelping
        return (passed, passed
            ? "预览:进入时 \(onEntry) 个 · 直径估小后 \(whenTooSmall) 个 · 调回 \(whenRight) 个 · 离开即清空"
                + " · 一次取出 \(points.count) 个符号(最大偏差 \(String(format: "%.3f", worst))px)"
                + " · 再匹配一次仍是 \(twice) 个(不翻倍)"
                + " · 一次撤销「符号匹配」回到空,栈里没有第二步同名动作"
            : "预览 进入=\(onEntry) 估小=\(whenTooSmall) 调回=\(whenRight) 离开清空=\(droppedOnLeaving)"
                + " · 取出=\(points.count)/\(expected) 最大偏差 \(String(format: "%.3f", worst))"
                + " · 再匹配=\(twice) 标签=\(label ?? "无") 撤销=\(undone ?? "无") 回到空=\(backToNothing)"
                + " 没有重复记录=\(noSecondHelping)")
    }

    /// A legend key is the same colour as the data and must not become a point.
    ///
    /// The renderer draws it at three times the marker size, which is what a
    /// figure legend does — and what makes this testable: without a size filter
    /// the matcher returns it, and the resulting curve has one point sitting in
    /// the corner of the plot that no measurement ever produced.
    private static func symbolMatchingLeavesTheLegendAlone() -> (passed: Bool, detail: String) {
        guard let probe = scatterCanvas(count: 20, legendSwatch: true) else {
            return (false, "无法构建散点画布")
        }
        let canvas = probe.canvas
        canvas.selectLine(id: probe.id)
        canvas.tool = .symbolMatch
        let preview = canvas.symbolPreview
        let expected = probe.chart.markerCentres.count
        guard let legend = probe.chart.legendCentre else { return (false, "固定装置没有画出图例") }

        let onData = preview?.points.filter { hypot($0.x - legend.x, $0.y - legend.y) < 40 }.count ?? -1
        let passed = preview?.points.count == expected && onData == 0
            && (preview?.rejectedTooLarge ?? 0) >= 1
        return (passed, passed
            ? "找到 \(expected) 个符号,图例附近 0 个 · 图例被记为「过大」\(preview?.rejectedTooLarge ?? 0) 个"
            : "找到 \(preview?.points.count ?? -1)/\(expected),图例附近 \(onData) 个,"
                + "过大 \(preview?.rejectedTooLarge ?? -1) 个")
    }

    // MARK: - 点编辑与数据表 (FR-6.4 / FR-7.2)

    /// Press, drag and release, through the handlers the canvas is driven by.
    ///
    /// All three events: the edit lands on the press and the *step* is recorded on
    /// the release, so a check that stopped after the drag would be inspecting a
    /// gesture that never closed — and would pass against a canvas that recorded
    /// nothing at all.
    @discardableResult
    private static func dragPoint(_ canvas: CanvasView,
                                  from: PixelPoint, to: PixelPoint) -> Bool {
        guard let down = dragEvent(canvas, .leftMouseDown, CGPoint(x: from.x, y: from.y)),
              let moved = dragEvent(canvas, .leftMouseDragged, CGPoint(x: to.x, y: to.y)),
              let up = dragEvent(canvas, .leftMouseUp, CGPoint(x: to.x, y: to.y))
        else { return false }
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: moved)
        canvas.mouseUp(with: up)
        return true
    }

    /// Where an edit actually lands, given the canvas clamps to the picture.
    ///
    /// Computed here rather than hoped for: a target picked a few pixels inside
    /// the image is inside, but the check should be about the edit and not about
    /// the fixture having been lucky about its margins.
    private static func clamped(_ p: PixelPoint, on canvas: CanvasView) -> PixelPoint {
        guard let buffer = canvas.buffer else { return p }
        return PixelPoint(x: min(max(p.x, 0), Double(buffer.width - 1)),
                          y: min(max(p.y, 0), Double(buffer.height - 1)))
    }

    /// Dragging a marker moves that point and nothing else.
    ///
    /// Three claims in one pass, each a different way the tool could be wrong: the
    /// grabbed point is the one that moves, the curve still has the same number of
    /// points, and the whole stroke is **one** undo step named after what it did.
    private static func pointEditingMovesExactlyOneMarker() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas() else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        canvas.tool = .editPoint
        canvas.selectLine(id: probe.id)
        guard let before = canvas.state.lines.first(where: { $0.id == probe.id })?.points,
              before.count >= 8 else { return (false, "固定装置的点太少") }

        // From the middle, so "the neighbours did not move" says something: a
        // check that grabbed the first point could not tell a correct drag from
        // one that shifted the whole array.
        let index = before.count / 2
        let grabbed = before[index]
        let target = clamped(PixelPoint(x: grabbed.x + 15, y: grabbed.y - 11), on: canvas)
        guard target != grabbed else { return (false, "固定装置太小,移动不出画面") }

        guard dragPoint(canvas, from: grabbed, to: target),
              let after = canvas.state.lines.first(where: { $0.id == probe.id })?.points else {
            return (false, "构造不出拖拽事件")
        }
        let movedTheRightOne = after[index] == target
        var othersIntact = true
        for i in before.indices where i != index && before[i] != after[i] { othersIntact = false }
        let sameCount = after.count == before.count
        let label = canvas.undoLabel
        let undone = canvas.undo()
        let restored = canvas.state.lines.first(where: { $0.id == probe.id })?.points == before

        let passed = movedTheRightOne && othersIntact && sameCount
            && label == "移动点" && undone == "移动点" && restored
        return (passed, passed
            ? "第 \(index + 1) 个点移到 (\(Int(target.x)),\(Int(target.y))) · 其余 \(before.count - 1) 个未动"
                + " · 点数不变 · 一步撤销「移动点」且能还原"
            : "移动到位=\(movedTheRightOne) 其余未动=\(othersIntact) 点数不变=\(sameCount)"
                + " 标签=\(label ?? "无") 撤销=\(undone ?? "无") 还原=\(restored)")
    }

    /// A click on the line between two markers inserts one there; ⌫ takes it back.
    ///
    /// The point of the check is where the new point *ends up in the order*: a
    /// curve's polyline is what its sequence says, so a point inserted at the
    /// wrong end would look correct on screen — it is at the right coordinates —
    /// and draw a line right across the chart on the next redraw.
    private static func pointEditingInsertsOnTheLineThenDeletes() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas() else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        canvas.tool = .editPoint
        canvas.selectLine(id: probe.id)
        guard let before = canvas.state.lines.first(where: { $0.id == probe.id })?.points,
              before.count >= 8 else { return (false, "固定装置的点太少") }

        // The midpoint of a segment: on the chord by construction, so its distance
        // to the line is zero while its distance to either end is half a spacing —
        // which is the region the insert gesture owns now that the nearest feature
        // wins. (Under a marker-first rule this click would have grabbed a marker,
        // and inserting into an area-digitised curve would be impossible.)
        let index = before.count / 2
        let a = before[index], b = before[index + 1]
        let midpoint = PixelPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        guard click(at: midpoint, on: canvas),
              let inserted = canvas.state.lines.first(where: { $0.id == probe.id })?.points else {
            return (false, "点不下去")
        }
        guard inserted.count == before.count + 1 else {
            return (false, "点数没有增加:\(before.count) → \(inserted.count)(点到的可能是标记而不是连线)")
        }
        guard let position = inserted.firstIndex(where: { !before.contains($0) }) else {
            return (false, "找不到新插入的点")
        }
        let insertLabel = canvas.undoLabel
        let between = position > 0 && position + 1 < inserted.count
            && inserted[position - 1] == a && inserted[position + 1] == b

        // ⌫ on the point that was just placed. Through the canvas' own command —
        // the key itself is delivered by AppKit and cannot be synthesised here, and
        // what is being checked is what the key does, not that it is bound.
        let deleted = canvas.deleteSelectedPoint()
        let afterDelete = canvas.state.lines.first(where: { $0.id == probe.id })?.points
        let deleteLabel = canvas.undoLabel
        let goneAgain = afterDelete == before
        let undone = canvas.undo()

        let passed = between && insertLabel == "插入点" && deleted && goneAgain
            && deleteLabel == "删除点" && undone == "删除点"
        return (passed, passed
            ? "新点插在第 \(position + 1) 位,两邻正是 (\(Int(a.x)),\(Int(a.y))) 与 (\(Int(b.x)),\(Int(b.y)))"
                + " · 撤销名「插入点」 · ⌫ 删掉后曲线与原来逐点相同 · 撤销名「删除点」"
            : "落在两端之间=\(between)(位置 \(position)) 插入标签=\(insertLabel ?? "无")"
                + " 删除=\(deleted) 复原=\(goneAgain) 删除标签=\(deleteLabel ?? "无") 撤销=\(undone ?? "无")")
    }

    /// The bug this whole section is arranged around.
    ///
    /// On a reversed curve the first marker on screen is the **last** point in
    /// storage. An editor that used the position it drew at as the index it wrote
    /// to would move the point at the other end — and the drag would look like it
    /// had worked, because a marker did move, just not the one under the cursor.
    /// Nothing on screen distinguishes the two outcomes except *which* marker
    /// travelled, which is exactly what is asserted here.
    private static func pointEditingWritesTheDisplayedMarkerNotTheStoredIndex()
        -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas() else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        canvas.selectLine(id: probe.id)
        canvas.setOrder(.reversed, for: probe.id)
        canvas.tool = .editPoint
        guard let line = canvas.state.lines.first(where: { $0.id == probe.id }),
              let displayedFirst = line.orderedPoints.first,
              let storedFirst = line.points.first,
              displayedFirst != storedFirst else { return (false, "固定装置首尾重合,验不出区别") }

        let target = clamped(PixelPoint(x: displayedFirst.x + 13, y: displayedFirst.y + 9), on: canvas)
        guard dragPoint(canvas, from: displayedFirst, to: target),
              let after = canvas.state.lines.first(where: { $0.id == probe.id })?.points else {
            return (false, "构造不出拖拽事件")
        }
        let storedLastMoved = after.last == target
        let storedFirstIntact = after.first == storedFirst
        let stillReversed = canvas.state.lines.first(where: { $0.id == probe.id })?.order == .reversed
        let shownFirst = canvas.state.lines.first(where: { $0.id == probe.id })?.orderedPoints.first

        let passed = storedLastMoved && storedFirstIntact && stillReversed && shownFirst == target
        return (passed, passed
            ? "屏幕上第一个标记动的是存储里的末点 (\(Int(target.x)),\(Int(target.y))) · 存储首点未动 · 顺序仍是反转"
            : "末点动=\(storedLastMoved) 首点未动=\(storedFirstIntact) 顺序保持=\(stillReversed)"
                + " 显示首点=\(String(describing: shownFirst))")
    }

    /// The data table, on a calibrated curve — FR-7.2.
    ///
    /// Five claims, each a way it could be wrong: a typed number becomes the
    /// chart value under the calibration, the **other** coordinate does not shift
    /// (only the edited axis goes through the mapping), a row addresses the marker
    /// the table is *showing* rather than the one at that storage position, text
    /// that is not a number is refused, and a row that is not there is refused.
    private static func thePointTableEditsTheDisplayedPoint() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas() else { return (false, "无法构建画布") }
        let canvas = probe.canvas
        canvas.selectLine(id: probe.id)
        canvas.applyCalibration(anchors: CalibrationAnchors(xStart: PixelPoint(x: 100, y: 560),
                                                           xEnd: PixelPoint(x: 800, y: 560),
                                                           yStart: PixelPoint(x: 100, y: 560),
                                                           yEnd: PixelPoint(x: 100, y: 60)),
                                xStartValue: 0, xEndValue: 10,
                                yStartValue: 0, yEndValue: 5,
                                xIsLogarithmic: false, yIsLogarithmic: false)
        guard let calibration = canvas.state.calibration,
              let points = canvas.state.lines.first(where: { $0.id == probe.id })?.orderedPoints,
              points.count > 4 else { return (false, "标定或曲线没建起来") }

        let panel = SidebarView(frame: NSRect(x: 0, y: 0, width: 272, height: 480))
        let wiring = PointEditProbe(canvas: canvas)
        panel.delegate = wiring
        panel.update(lines: canvas.state.lines, calibration: calibration, activeID: probe.id)

        let row = 3
        let before = points[row]
        let beforeData = try? calibration.data(fromPixel: before)

        guard let accepted = panel.commitPointValue(row: row, axis: .y, text: " 3.25 ") else {
            return (false, "输入被拒(那是个合法的数)")
        }
        guard let edited = canvas.state.lines.first(where: { $0.id == probe.id })?.orderedPoints[row],
              let editedData = try? calibration.data(fromPixel: edited) else {
            return (false, "取不回改后的点")
        }
        let yIsTyped = abs(editedData.y - 3.25) < 1e-9
        // The property that makes per-axis conversion worth the extra code: an edit
        // to y must not move x by a bit, or a table session would slowly drift a
        // curve that the user was only correcting vertically.
        let xUntouched = edited.x == before.x

        // And the row is a position on **screen**, not in storage. Reversed order
        // puts the stored last point in row 0, so editing row 0 has to write the
        // marker the table is showing — an implementation that used the row number
        // as a storage index would edit the far end of the curve and leave the
        // typed number nowhere on the chart.
        canvas.setOrder(.reversed, for: probe.id)
        panel.update(lines: canvas.state.lines, calibration: calibration, activeID: probe.id)
        _ = panel.commitPointValue(row: 0, axis: .x, text: "7.5")
        let reversedLine = canvas.state.lines.first(where: { $0.id == probe.id })
        let lastEndTookIt = reversedLine?.orderedPoints.first.flatMap {
            try? calibration.data(fromPixel: $0)
        }.map { abs($0.x - 7.5) < 1e-9 } ?? false
        let firstEndIntact = reversedLine?.orderedPoints.last == points.first

        // Refusals. A comma is not accepted on purpose: it is a thousands
        // separator as often as a decimal point, and 「1,000」 read as 1.000 would
        // be wrong by a factor of a thousand with nothing on screen to show it.
        // Read *here*, after the order change above: comparing against a value
        // captured before it would be comparing two different rows.
        let rowBeforeRefusal = canvas.state.lines.first(where: { $0.id == probe.id })?
            .orderedPoints[row]
        let refusedText = panel.commitPointValue(row: row, axis: .y, text: "3,5") == nil
        let unchangedAfterRefusal = canvas.state.lines.first(where: { $0.id == probe.id })?
            .orderedPoints[row] == rowBeforeRefusal
        let refusedRow = panel.commitPointValue(row: 9_999, axis: .x, text: "1") == nil

        let passed = yIsTyped && xUntouched && lastEndTookIt && firstEndIntact
            && refusedText && unchangedAfterRefusal && refusedRow
            && wiring.edits == 2 && accepted == 3.25
        return (passed, passed
            ? "输入 3.25 → Y=\(String(format: "%.2f", editedData.y)),X 像素未动(原 \(String(format: "%.1f", beforeData?.x ?? 0)) → \(String(format: "%.1f", editedData.x)))"
                + " · 反转序下改第 1 行写的是末点 · 「3,5」被拒且值不变 · 越界行被拒"
            : "Y 写入=\(yIsTyped) X 未动=\(xUntouched) 首行写末点=\(lastEndTookIt) 另一端未动=\(firstEndIntact)"
                + " 文本被拒=\(refusedText) 拒后不变=\(unchangedAfterRefusal)"
                + " 越界被拒=\(refusedRow) 委托次数=\(wiring.edits) 返回值=\(accepted)")
    }

    // MARK: - 项目文件 (project files)
    //
    // The container's own encoding — the prologue, the offsets, which failure is
    // which — is unit-tested in `ProjectFileTests`, where a made-up state makes
    // every field easy to name and compare. What is left for here is the part a
    // unit test cannot reach: that a *session* built through the real canvas
    // paths survives a real file and a real reopen, that the curve that comes
    // back is immediately usable rather than merely present, and that the
    // window's 「未保存」 mark follows the file rather than the keyboard.

    /// The chart the project checks are built on: its PNG bytes, its pixel size,
    /// and a pixel known to be on the curve.
    ///
    /// A PNG rather than a `CGImage`, because the promise the format makes is
    /// about *bytes* — the image is written to disk and read back — and a
    /// fixture that never had bytes to begin with could not tell a verbatim copy
    /// from a re-encode.
    private static func sampleChartPNG()
        -> (png: Data, width: Int, height: Int, seed: PixelPoint)? {
        let chart = SyntheticChart.render()
        guard let cg = SampleChartWriter.makeCGImage(from: chart.buffer) else { return nil }
        // The PNG is the point: `CGImage` in, bytes out, so the fixture has an
        // original for the round trip to be compared against.
        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        guard let png,
              let seed = chart.curvePixels.dropFirst(chart.curvePixels.count / 2).first
        else { return nil }
        return (png, cg.width, cg.height, seed)
    }

    /// A canvas with only a picture on it — the state `⌘O` produces, before any
    /// work has been done to it.
    private static func bareImageCanvas(png: Data, width: Int, height: Int,
                                        name: String = "chart.png")
        -> (canvas: CanvasView, window: NSWindow)? {
        guard let image = NSImage(data: png) else { return nil }
        let frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        let canvas = CanvasView(frame: frame)
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        guard canvas.load(image: image, data: png, name: name) else { return nil }
        canvas.layoutSubtreeIfNeeded()
        return (canvas, window)
    }

    /// A canvas carrying a real chart, calibrated and digitised the way the app
    /// does it.
    ///
    /// Built through the real paths on purpose. Handing a `ProjectState` to the
    /// writer and reading it straight back would prove only that `JSONEncoder`
    /// works; the promise is that a *session* survives, so the fixture is made
    /// the way a session is made — anchors clicked onto pixels, a colour sampled
    /// off the image, points found by an area pass.
    private static func projectFixture(name: String = "chart.png")
        -> (canvas: CanvasView, png: Data, window: NSWindow)? {
        guard let sample = sampleChartPNG(),
              let fixture = bareImageCanvas(png: sample.png, width: sample.width,
                                            height: sample.height, name: name) else { return nil }
        let canvas = fixture.canvas

        // Deliberately not the image's corners, and with a non-zero origin and a
        // log axis on Y: a reopen that fell back to "the whole picture, from
        // zero, linearly" would match the corners and fail these.
        canvas.applyCalibration(anchors: CalibrationAnchors(
                                    xStart: PixelPoint(x: 44, y: 512),
                                    xEnd: PixelPoint(x: 572, y: 512),
                                    yStart: PixelPoint(x: 44, y: 512),
                                    yEnd: PixelPoint(x: 44, y: 36)),
                                xStartValue: 100, xEndValue: 700,
                                yStartValue: 0.5, yEndValue: 25,
                                xIsLogarithmic: false, yIsLogarithmic: true)
        canvas.setGridSpacing(13)

        canvas.tool = .pickLineColor
        canvas.addLine()
        guard let id = canvas.state.activeLineID else { return nil }
        click(at: sample.seed, on: canvas)
        guard canvas.state.activeLine?.lineColor != nil else { return nil }

        canvas.tool = .gridDigitize
        canvas.selectLine(id: id)
        guard dragAcrossWholeImage(canvas, width: sample.width, height: sample.height) else {
            return nil
        }
        canvas.layoutSubtreeIfNeeded()
        return (canvas, sample.png, fixture.window)
    }

    /// One area pass over the whole picture, through the mouse handlers.
    @discardableResult
    private static func dragAcrossWholeImage(_ canvas: CanvasView, width: Int, height: Int) -> Bool {
        let end = CGPoint(x: Double(width - 2), y: Double(height - 2))
        guard let down = dragEvent(canvas, .leftMouseDown, CGPoint(x: 2, y: 2)),
              let drag = dragEvent(canvas, .leftMouseDragged, end),
              let up = dragEvent(canvas, .leftMouseUp, end) else { return false }
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: drag)
        canvas.mouseUp(with: up)
        return true
    }

    /// A fresh canvas with the document opened into it, the way the window does
    /// it. Nil when the bytes do not yield an image, which is the refusal the
    /// app reports rather than opening an empty project.
    private static func makeCanvasShowing(_ document: ProjectDocument) -> (canvas: CanvasView,
                                                                           window: NSWindow)? {
        guard let image = NSImage(data: document.imageData) else { return nil }
        let frame = NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        let canvas = CanvasView(frame: frame)
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        guard canvas.load(project: document) else { return nil }
        canvas.layoutSubtreeIfNeeded()
        return (canvas, window)
    }

    /// Through the filesystem, not in memory: the feature is "save it and open
    /// it next time", and a check that never touched a disk would not notice a
    /// reader and a writer that agreed with each other and nothing else.
    private static func writeToTemporaryFile(_ document: ProjectDocument) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gd-selftest-\(UUID().uuidString).\(ProjectFile.fileExtension)")
        do {
            try document.serialized().write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Write a session out, read it back into a new canvas, and compare what the
    /// user would see.
    ///
    /// Compared at the level of the numbers on screen as well as the structs: the
    /// last check converts the reopened points through the reopened calibration
    /// and compares the chart values. A file that kept every pixel but lost the
    /// mapping would satisfy every field comparison above it and still show the
    /// wrong numbers.
    private static func projectSurvivesAFileRoundTrip() -> (passed: Bool, detail: String) {
        guard let fixture = projectFixture(),
              let document = fixture.canvas.projectDocument(appVersion: "selftest"),
              let url = writeToTemporaryFile(document),
              let reread = try? ProjectDocument(serialized: Data(contentsOf: url)) else {
            return (false, "往返失败:写不出去或读不回来")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let reopened = makeCanvasShowing(reread) else {
            return (false, "项目文件里的图片解不开")
        }

        let before = fixture.canvas.state
        let after = reopened.canvas.state
        var problems: [String] = []

        if after.calibration != before.calibration { problems.append("标定映射不一致") }
        if after.calibrationAnchors != before.calibrationAnchors {
            problems.append("四个标定锚点不一致 —— 重新打开后轴线会画在别处")
        }
        if after.activeLineID != before.activeLineID { problems.append("当前选中的曲线不一致") }
        if after.gridSpacing != before.gridSpacing {
            problems.append("网格间距 \(after.gridSpacing) ≠ \(before.gridSpacing)")
        }
        if after.traceSpacing != before.traceSpacing { problems.append("取点密度不一致") }
        if after.defaultBackgroundColor != before.defaultBackgroundColor {
            problems.append("默认背景色不一致")
        }
        if after.defaultColorTolerance != before.defaultColorTolerance {
            problems.append("默认颜色容差不一致")
        }
        if after.lines.count != before.lines.count {
            problems.append("曲线数 \(after.lines.count) ≠ \(before.lines.count)")
        }
        for (original, restored) in zip(before.lines, after.lines) {
            let name = original.name
            if restored.id != original.id { problems.append("「\(name)」的 id 变了") }
            if restored.name != original.name { problems.append("曲线名 \(restored.name) ≠ \(name)") }
            if restored.color != original.color { problems.append("「\(name)」的显示色变了") }
            if restored.lineColor != original.lineColor { problems.append("「\(name)」的取色丢了") }
            if restored.backgroundColor != original.backgroundColor {
                problems.append("「\(name)」的背景色丢了")
            }
            if restored.points != original.points {
                problems.append("「\(name)」点位 \(restored.points.count)/\(original.points.count) 不一致")
            }
            if restored.order != original.order { problems.append("「\(name)」的取点顺序变了") }
            if restored.sweptOrder != original.sweptOrder { problems.append("「\(name)」的重排记录变了") }
            if restored.isVisible != original.isVisible { problems.append("「\(name)」的显示开关变了") }
        }

        // The numbers, through both calibrations. This is the check that would
        // catch a file which preserved the pixels and the mapping separately but
        // somehow put them back out of step.
        if let bCal = before.calibration, let aCal = after.calibration,
           let bLine = before.lines.first, let aLine = after.lines.first {
            let bValues = (try? bLine.dataPoints(using: bCal)) ?? []
            let aValues = (try? aLine.dataPoints(using: aCal)) ?? []
            if bValues.isEmpty { problems.append("原场景一个点都没有,这条检查是空的") }
            if aValues != bValues { problems.append("换算出的图表数值逐点不一致") }
        } else {
            problems.append("有一侧没有标定或没有曲线")
        }

        let passed = problems.isEmpty
        return (passed, passed
            ? "\(after.lines.count) 条曲线 · \(after.totalPointCount) 点 · 标定与锚点一致 · 数值逐点相同"
            : problems.joined(separator: "; "))
    }

    /// The image half of the promise: what comes back is the file that went in,
    /// not a re-encode of it.
    ///
    /// Both levels are checked because either alone can pass while the other is
    /// broken. The bytes say the file carries the original; the decoded buffer
    /// says the app reopening it sees the same picture — the same pixels at the
    /// same coordinates, which is the space every stored point is measured in.
    private static func projectKeepsTheOriginalImageBytes() -> (passed: Bool, detail: String) {
        guard let fixture = projectFixture(),
              let document = fixture.canvas.projectDocument(),
              let url = writeToTemporaryFile(document),
              let reread = try? ProjectDocument(serialized: Data(contentsOf: url)) else {
            return (false, "往返失败")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let reopened = makeCanvasShowing(reread),
              let original = fixture.canvas.buffer,
              let restored = reopened.canvas.buffer else {
            return (false, "有一侧没有位图")
        }

        let bytesMatch = reread.imageData == fixture.png
        let sizeMatches = original.width == restored.width && original.height == restored.height
        let pixelsMatch = sizeMatches && original.pixels == restored.pixels
        let passed = bytesMatch && pixelsMatch
        return (passed, passed
            ? "\(fixture.png.count) 字节原样保存 · 解出来 \(original.width)×\(original.height) 逐像素相同"
            : "字节\(bytesMatch ? "一致" : "被重编码过") · 尺寸\(sizeMatches ? "一致" : "不同")"
                + " · 像素\(pixelsMatch ? "相同" : "被改过")")
    }

    /// A reopened curve can be digitised into straight away.
    ///
    /// The failure this guards is silent. Restoring the state but not the
    /// foreground mask would leave a curve that looks right, lists the right
    /// points, and quietly takes none when the user carries on — because the mask
    /// the tools sample through is gone. Asserted by doing the work rather than
    /// by inspecting the cache: the curve is emptied and the region taken again,
    /// and what matters is whether points come back.
    private static func reopenedProjectIsReadyForMorePoints() -> (passed: Bool, detail: String) {
        guard let fixture = projectFixture(),
              let document = fixture.canvas.projectDocument(),
              let reopened = makeCanvasShowing(document),
              let width = fixture.canvas.buffer?.width,
              let height = fixture.canvas.buffer?.height else {
            return (false, "无法重建场景")
        }
        let canvas = reopened.canvas
        guard let id = canvas.state.activeLineID,
              let before = canvas.state.activeLine?.points.count, before > 0 else {
            return (false, "重开的项目里没有点")
        }

        canvas.clearActiveLinePoints()
        guard canvas.state.activeLine?.points.isEmpty == true else {
            return (false, "清空当前曲线的点失败")
        }
        // The tool has to be put in hand, or the drag pans the view instead of
        // sampling it and the check would pass or fail for the wrong reason.
        canvas.tool = .gridDigitize
        canvas.selectLine(id: id)
        guard dragAcrossWholeImage(canvas, width: width, height: height) else {
            return (false, "构造不了拖拽事件")
        }
        let after = canvas.state.activeLine?.points.count ?? 0
        let passed = after > 0
        return (passed, passed
            ? "清空后重新框选,又取到 \(after) 点(\(before) → 0 → \(after)),掩膜确实随文件重建了"
            : "重开后重新框选一个点也取不到 —— 掩膜没有随文件回来")
    }

    /// An opened project starts with an empty history.
    ///
    /// Opened into the fixture's **own** canvas, which is carrying a real stack of
    /// actions from the session that built it. A fresh canvas would report the
    /// same empty history whatever the loader did — it has none to begin with —
    /// so the check has to replace a document that has work behind it, which is
    /// exactly what the user does when they open a file over what they were doing.
    ///
    /// The snapshots a file represents are not a *history*; they are one state.
    /// Keeping the previous document's stack would let `⌘Z` splice two charts
    /// together, and the first press on a freshly opened file is precisely when
    /// the user has no idea what is on it.
    private static func openingAProjectForgetsTheHistory() -> (passed: Bool, detail: String) {
        guard let fixture = projectFixture(),
              let document = fixture.canvas.projectDocument() else { return (false, "无法重建场景") }
        let canvas = fixture.canvas
        let couldUndoBefore = canvas.canUndo

        guard canvas.load(project: document) else { return (false, "项目没打开") }
        let emptyBothWays = !canvas.canUndo && !canvas.canRedo
        let undone = canvas.undo()
        let passed = couldUndoBefore && emptyBothWays && undone == nil
        return (passed, passed
            ? "覆盖打开前有历史(可撤销=\(couldUndoBefore)) · 打开后两侧清空 · ⌘Z 无动作"
            : "开文件前可撤销=\(couldUndoBefore) · 打开后可撤销=\(canvas.canUndo)"
                + " 可恢复=\(canvas.canRedo) · ⌘Z 却返回 \(undone ?? "nil")")
    }

    /// Files that are not projects are refused, and told apart.
    ///
    /// Fed through the reader the window uses rather than a stand-in, because the
    /// point is the sentence the user ends up reading: 「换个新版本」 and 「文件
    /// 被截断了」 want opposite responses, and one generic 「读取失败」 would send
    /// them to the wrong one. The last case is different in kind — the container
    /// parses and it is the *image* inside that is broken — and it is here
    /// because it is the failure that would otherwise look like success.
    private static func brokenProjectFilesAreRefused() -> (passed: Bool, detail: String) {
        guard let fixture = projectFixture(),
              let document = fixture.canvas.projectDocument(),
              let good = try? document.serialized() else { return (false, "无法重建场景") }

        let headerLength = Int(good[12]) | Int(good[13]) << 8
            | Int(good[14]) << 16 | Int(good[15]) << 24
        let bodyStart = 16 + headerLength

        var newer = good
        newer[8] = UInt8(ProjectFile.currentVersion + 1)
        newer[9] = 0

        var headerTooLong = good
        headerTooLong[12] = 0xFF; headerTooLong[13] = 0xFF
        headerTooLong[14] = 0xFF; headerTooLong[15] = 0x7F

        let cases: [(name: String, data: Data, expected: ProjectFileError)] = [
            ("一张普通 PNG", fixture.png, .notAProjectFile),
            ("头部长度报大了", headerTooLong, .truncatedHeader),
            ("更高版本的项目", newer, .unsupportedVersion(ProjectFile.currentVersion + 1)),
            ("只剩头部、没有图片", Data(good.prefix(bodyStart)), .missingImage),
        ]

        var failures: [String] = []
        for entry in cases {
            do {
                _ = try ProjectDocument(serialized: entry.data)
                failures.append("\(entry.name):竟然读进去了")
            } catch let error as ProjectFileError {
                if error != entry.expected {
                    failures.append("\(entry.name):报的是 \(error),应为 \(entry.expected)")
                }
                if error.localizedDescription.isEmpty {
                    failures.append("\(entry.name):没有给出可读说明")
                }
            } catch {
                failures.append("\(entry.name):抛出了非项目错误 \(error)")
            }
        }

        // The header is fine and the image behind it is cut short: not a reader
        // failure at all, but the canvas must still refuse. Opening it would show
        // an empty window with the curves' data in it and look like the file had
        // lost its picture.
        let clipped = Data(good.prefix(bodyStart + 64))
        if let parsed = try? ProjectDocument(serialized: clipped) {
            if makeCanvasShowing(parsed) != nil {
                failures.append("图片残缺的项目竟然打开成功了")
            }
        } else {
            failures.append("图片残缺的项目在解析头部就失败了,应当由画布拒绝")
        }

        let passed = failures.isEmpty
        return (passed, passed
            ? "PNG · 谎报头长 · 高版本 · 无图片 · 图片残缺 各自被正确拒绝并给出说明"
            : failures.joined(separator: "; "))
    }

    /// The 「未保存」 mark tracks the file, not the keyboard.
    ///
    /// Five moments, and the middle one is the whole reason this is a comparison
    /// rather than a flag: an **undo back to the saved state must clear the
    /// mark**. An implementation that set a boolean on every mutation would go on
    /// claiming the document was changed when what is on screen is exactly what is
    /// on disk — and would then ask about saving on quit for edits the user had
    /// already taken back.
    private static func theUnsavedMarkFollowsTheFile() -> (passed: Bool, detail: String) {
        guard let fixture = projectFixture(),
              let document = fixture.canvas.projectDocument() else { return (false, "无法重建场景") }
        let canvas = fixture.canvas
        canvas.markSaved()

        let cleanAfterSaving = !canvas.hasUnsavedChanges
        canvas.addLine()
        let dirtyAfterEdit = canvas.hasUnsavedChanges
        _ = canvas.undo()
        let cleanAfterUndo = !canvas.hasUnsavedChanges

        // And a save is what makes an edit clean without taking it back.
        canvas.addLine()
        canvas.markSaved()
        let cleanAfterSecondSave = !canvas.hasUnsavedChanges

        // Opening a chart is not an edit, however much ⌘O feels like one; and
        // opening a project is not one either, however much work that file holds.
        let openedImage = sampleChartPNG().flatMap {
            bareImageCanvas(png: $0.png, width: $0.width, height: $0.height)
        }
        let cleanAfterImage = openedImage?.canvas.hasUnsavedChanges == false
        let cleanAfterProject = makeCanvasShowing(document)?.canvas.hasUnsavedChanges == false

        let passed = cleanAfterSaving && dirtyAfterEdit && cleanAfterUndo
            && cleanAfterSecondSave && cleanAfterImage && cleanAfterProject
        return (passed, passed
            ? "刚存过=干净 · 改一下=脏 · 撤销回去=干净 · 再存=干净 · 开图/开项目=干净"
            : "刚存过\(cleanAfterSaving ? "干净" : "却标脏") · 改一下\(dirtyAfterEdit ? "标脏" : "没标脏")"
                + " · 撤销回去\(cleanAfterUndo ? "干净" : "仍标脏")"
                + " · 再存\(cleanAfterSecondSave ? "干净" : "仍标脏")"
                + " · 开图\(cleanAfterImage ? "干净" : "标脏")"
                + " · 开项目\(cleanAfterProject ? "干净" : "标脏")")
    }

    /// The menu bar's own promises, which nothing else can see.
    ///
    /// Built through the real `buildMenu`, not a description of it, because a
    /// shortcut collision is close to silent. **AppKit will clear the duplicate
    /// itself**: a deliberately duplicated ⌘S in the File menu comes back out of
    /// the finished menu as `[保存项目] key=[]`, the item simply stops answering
    /// to its shortcut and looks like a command that does not work. The same
    /// experiment in the Operations menu left *both* owners in place.
    ///
    /// So the check is written to look for the symptom rather than for the cause.
    /// A collision means some command has **lost** its shortcut — so the commands
    /// that must have one are named, and a collision anywhere in that list shows
    /// up as the loser going missing whether or not AppKit cleaned it up first.
    /// The backstop below covers the other half, where both survive.
    ///
    /// One pair had been sitting in the Operations menu since before anything
    /// looked: ⌘R on both 清除标定并重来 and 重新选点. And `⌘S` has to be 保存 —
    /// it is what every Mac user's hand does without asking, and it used to open a
    /// calibration that would eat the next four clicks on the chart.
    private static func theMenuBarKeepsItsPromises() -> (passed: Bool, detail: String) {
        let delegate = AppDelegate()
        delegate.buildMenu()
        guard let main = NSApp.mainMenu else { return (false, "没有主菜单") }

        var owners: [String: [String]] = [:]
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                let key = item.keyEquivalent
                if !key.isEmpty, !item.isSeparatorItem {
                    let mods = item.keyEquivalentModifierMask
                    var signature = mods.contains(.control) ? "⌃" : ""
                    signature += mods.contains(.option) ? "⌥" : ""
                    signature += mods.contains(.shift) ? "⇧" : ""
                    signature += mods.contains(.command) ? "⌘" : ""
                    signature += key.uppercased()
                    owners[signature, default: []].append(item.title)
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(main)

        var problems: [String] = []

        // The shortcut contract, command by command. Both halves matter: the
        // file commands because they are the new feature, and the tools because
        // this is where the ⌘R collision was living.
        let expected: [(shortcut: String, command: String)] = [
            ("⌘O", "打开…"),
            ("⌘S", "保存项目"),
            ("⇧⌘S", "项目另存为…"),
            ("⌘C", "Copy Data to Clipboard (复制全部曲线)"),
            ("⌥⌘C", "Copy Current Curve (复制当前曲线)"),
            ("⇧⌘I", "Show Image (显示原图)"),
            ("⇧⌘D", "Data View (数据视图)"),
            ("⌘W", "Close Window"),
            ("⌘Z", "撤销"),
            ("⇧⌘Z", "重做"),
            ("⌥⌘S", "Set the Scale (标定坐标系)"),
            ("⌥⌘R", "Recalibrate (清除标定并重来)"),
            ("⌘R", "Re-digitize (重新选点)"),
            ("⌘B", "Reorder Points by Sweep (点重排)"),
            ("⌘E", "Eraser (橡皮擦)"),
            ("⌘M", "Match Symbols (符号匹配)"),
            ("⇧⌘E", "Edit Point (点编辑)"),
            ("⌘D", "Digitize Area (区域取点)"),
            ("⌘1", "Browse Tool (浏览:缩放平移)"),
        ]
        for entry in expected {
            let owner = owners[entry.shortcut]?.first
            if owner != entry.command {
                problems.append("\(entry.shortcut) 归了「\(owner ?? "空")」,应为 \(entry.command)")
            }
        }

        // The two export submenus must lead to *different* handlers. Wiring both
        // to the general one would leave 「只导出当前曲线」 quietly exporting
        // everything — which nobody notices until a figure comes back with five
        // curves in it. Compared by selector name because the handlers are
        // private to the delegate.
        func exportItems(_ submenuTitle: String) -> [NSMenuItem] {
            for item in main.items {
                guard let sub = item.submenu,
                      let carrier = sub.items.first(where: { $0.submenu?.title == submenuTitle })
                else { continue }
                return carrier.submenu?.items ?? []
            }
            return []
        }
        let allCurveItems = exportItems("Export Data")
        let activeCurveItems = exportItems("Export Current Curve")
        if allCurveItems.isEmpty || activeCurveItems.isEmpty {
            problems.append("导出菜单没建出来")
        }
        for item in allCurveItems where item.action.map(NSStringFromSelector) ?? "" != "exportData:" {
            problems.append("「\(item.title)」没接到导出全部曲线")
        }
        for item in activeCurveItems where item.action.map(NSStringFromSelector) ?? "" != "exportCurrentCurve:" {
            problems.append("「\(item.title)」没接到只导出当前曲线")
        }

        // The other half: the case AppKit leaves alone. Measured by giving two
        // Operations items the same key, which left both of them owning it — so
        // when this fires, the loser really has been left unreachable rather than
        // quietly repaired. It is deliberately the backstop and not the check:
        // in the File menu the duplicate was already gone by the time the menu
        // existed, and this loop would have found nothing.
        for (signature, titles) in owners.sorted(by: { $0.key < $1.key }) where titles.count > 1 {
            problems.append("\(signature) 同时给了 \(titles.joined(separator: " 和 "))")
        }

        // The type the open panel filters on is the one the bundle registers and
        // the writer names in the file. Three strings in three places; this is the
        // only one that can be compared at runtime.
        if UTType.graphDiggerProject.identifier != ProjectFile.typeIdentifier {
            problems.append("打开面板筛的类型标识与文件格式不符")
        }

        let passed = problems.isEmpty
        return (passed, passed
            ? "\(owners.count) 个快捷键各就各位 · ⌘S 保存 / ⇧⌘S 另存为 / ⌘O 打开 / ⌥⌘S 标定"
            : problems.joined(separator: "; "))
    }

    // MARK: - 点重排 (sweep reorder)

    /// Drives a real sweep along `path` with the reorder tool.
    ///
    /// The path is in image pixels — what the pointer is over — and becomes mouse
    /// events through the same conversion the other tool checks use, so this
    /// exercises the handlers rather than a shortcut into the algorithm.
    private static func sweepAlong(_ canvas: CanvasView, _ path: [PixelPoint],
                                   radius: CGFloat) -> CurveLine? {
        guard path.count >= 2 else { return nil }
        canvas.tool = .reorder
        canvas.eraserRadius = radius
        guard let down = dragEvent(canvas, .leftMouseDown, CGPoint(x: path[0].x, y: path[0].y)),
              let up = dragEvent(canvas, .leftMouseUp,
                                 CGPoint(x: path[path.count - 1].x, y: path[path.count - 1].y))
        else { return nil }
        canvas.mouseDown(with: down)
        for point in path.dropFirst() {
            guard let drag = dragEvent(canvas, .leftMouseDragged,
                                       CGPoint(x: point.x, y: point.y)) else { return nil }
            canvas.mouseDragged(with: drag)
        }
        canvas.mouseUp(with: up)
        return canvas.state.activeLine
    }

    /// Every `step`th point, always ending on the last one.
    ///
    /// Coarse on purpose: the whole point is that consecutive events are far
    /// enough apart that what happens *between* them is what decides the result.
    private static func coarsePath(_ points: [PixelPoint], step: Int) -> [PixelPoint] {
        var path = Swift.stride(from: 0, to: points.count, by: max(1, step)).map { points[$0] }
        if let last = points.last, path.last != last { path.append(last) }
        return path
    }

    /// The brush's path decides the numbering, driven through the real mouse
    /// handlers over a real curve.
    ///
    /// Two facts, and the second is the one that fails if the numbering falls back
    /// to anything position-based. Sweeping a single-valued curve left to right
    /// must number every point it passed over and leave the order as it was;
    /// sweeping the same curve right to left must give exactly the reverse. The
    /// path is sampled coarsely — about 64px between events against a 24pt ring —
    /// so a tool that only looked at the positions the pointer reported would miss
    /// every point in between: it is the leg resampling that makes the coverage
    /// complete, and this is the check that notices if it goes away.
    private static func reorderSweepFollowsTheBrushPath() -> (passed: Bool, detail: String) {
        guard let forwardProbe = singleCurveCanvas(),
              let forwardLine = forwardProbe.canvas.state.lines
                  .first(where: { $0.id == forwardProbe.id }),
              forwardLine.points.count > 60 else { return (false, "无法构建带点的画布") }
        let extracted = forwardLine.points
        let path = coarsePath(extracted, step: 8)

        guard let forward = sweepAlong(forwardProbe.canvas, path, radius: 24),
              let forwardSequence = forward.sweptOrder else {
            return (false, "扫过之后没有记下重排顺序")
        }

        // The same curve again, swept the other way.
        guard let backwardProbe = singleCurveCanvas(),
              let backwardLine = backwardProbe.canvas.state.lines
                  .first(where: { $0.id == backwardProbe.id }),
              backwardLine.points.count == extracted.count,
              let backward = sweepAlong(backwardProbe.canvas, Array(path.reversed()), radius: 24),
              backward.sweptOrder != nil else {
            return (false, "反向扫过之后没有记下重排顺序")
        }

        let allNumbered = forwardSequence.count == extracted.count
        let noDuplicates = Set(forwardSequence).count == forwardSequence.count
        let forwardKept = forward.orderedPoints.map(\.x) == extracted.map(\.x)
        let backwardReversed = backward.orderedPoints.map(\.x)
            == Array(backward.points.map(\.x).reversed())
        let passed = allNumbered && noDuplicates && forwardKept && backwardReversed
        return (passed, passed
            ? "\(forwardSequence.count)/\(extracted.count) 点 · 正向保序、反向得逆序"
            : "记下 \(forwardSequence.count)/\(extracted.count) 点"
                + " · 重复 \(forwardSequence.count - Set(forwardSequence).count)"
                + " · 正向\(forwardKept ? "保序" : "乱序")"
                + " · 反向\(backwardReversed ? "得逆序" : "不对")")
    }

    /// The ring's radius is measured in view points, so at a zoom other than 1:1
    /// it has to be converted before it is compared against the points, which are
    /// in image pixels.
    ///
    /// The project has already made this mistake once — `viewScale` carries a note
    /// written for exactly this — so the new ring is held to the standard the
    /// eraser is. A press with no movement is used, so the result is one set of
    /// points with no ordering to reason about, and the two candidate readings are
    /// shown to disagree before anything is swept, so the check cannot pass by the
    /// two happening to coincide.
    private static func reorderRingFollowsZoom() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas(zoomed: true),
              let line = probe.canvas.state.lines.first(where: { $0.id == probe.id }),
              line.points.count > 40 else { return (false, "无法构建缩放画布") }
        let canvas = probe.canvas
        let scale = canvas.viewScale
        guard scale < 0.9 else { return (false, "窗口没产生缩放(\(String(format: "%.2f", scale)))") }
        let before = line.points

        let viewRadius: CGFloat = 18
        // The wrong reading: treat the view-point radius as image pixels.
        let unconverted = Double(viewRadius)

        var centre: PixelPoint?
        for index in Swift.stride(from: before.count / 4, to: before.count * 3 / 4, by: 3) {
            let candidate = before[index]
            let right = pointsWithin(before, of: candidate,
                                     viewRadius: Double(viewRadius), scale: scale)
            let wrong = before.filter {
                hypot($0.x - candidate.x, $0.y - candidate.y) <= unconverted
            }
            if right.count > wrong.count + 1 { centre = candidate; break }
        }
        guard let centre else { return (false, "找不到两种半径结果不同的位置") }

        let shouldTake = pointsWithin(before, of: centre,
                                      viewRadius: Double(viewRadius), scale: scale)
        let unconvertedWouldTake = before.filter {
            hypot($0.x - centre.x, $0.y - centre.y) <= unconverted
        }

        canvas.tool = .reorder
        canvas.eraserRadius = viewRadius
        guard let down = dragEvent(canvas, .leftMouseDown, CGPoint(x: centre.x, y: centre.y)),
              let up = dragEvent(canvas, .leftMouseUp, CGPoint(x: centre.x, y: centre.y)) else {
            return (false, "事件构造失败")
        }
        canvas.mouseDown(with: down)
        canvas.mouseUp(with: up)

        guard let sequence = canvas.state.activeLine?.sweptOrder else {
            return (false, "按一下没有记下任何点")
        }
        let taken = Set(sequence.map { before[$0] })
        let passed = taken == Set(shouldTake)
            && shouldTake.count > unconvertedWouldTake.count
        return (passed, passed
            ? String(format: "缩放 %.0f%% · 编号 %d 点(不换算只会编号 %d)",
                     scale * 100, shouldTake.count, unconvertedWouldTake.count)
            : "编号了 \(taken.count) 点,应为 \(shouldTake.count)"
                + "(不换算会编号 \(unconvertedWouldTake.count))")
    }

    /// The parameter control lives in the info bar. At the narrowest width the
    /// window can be shown at, it must still sit clear of the status text and
    /// inside the bar — the failure mode is the two overlapping, which reads as
    /// corrupted text and hides the control. Hidden, it must give its width back
    /// rather than leaving a hole.
    private static func infoBarControlFitsAtMinimumWidth() -> (passed: Bool, detail: String) {
        let width = MainLayout.narrowestScreenWidth - MainLayout.sidebarWidth
        // Hosted in a window: a control with no window answers `hitTest` with
        // nil, so the reachability test below would fail for a bar that is
        // perfectly fine on screen. The bar is never used windowless either.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width,
                                                  height: MainLayout.infoBarHeight),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let bar = InfoBarView(frame: NSRect(x: 0, y: 0, width: width,
                                            height: MainLayout.infoBarHeight))
        window.contentView = bar
        // A long status line, not a short one: the two are laid out from
        // opposite edges and only fill the bar if there is enough text here.
        let statusText = "橡皮擦:圆圈碰到的数据点会被删除,拖拽可连续擦除,按 [ ] 调整圆圈大小"
        bar.update(step: "手工取点:逐点点击", status: statusText, lineSummary: "3 条曲线 · 512 点")
        bar.setParameter(.ringRadius, value: Double(CanvasView.eraserDefaultRadius))
        window.makeKeyAndOrderFront(nil)
        bar.layoutSubtreeIfNeeded()

        let sliders = bar.subviews.compactMap { $0 as? NSSlider }
        guard sliders.count == 1, let slider = sliders.first else {
            return (false, "状态条里应有 1 个滑块,实为 \(sliders.count) 个")
        }
        guard let status = bar.subviews.compactMap({ $0 as? NSTextField })
            .first(where: { $0.stringValue == statusText }) else {
            return (false, "找不到状态文字")
        }

        // Each control inside the bar...
        for view in [slider, status] as [NSView]
        where view.frame.minX < 0 || view.frame.maxX > width + 0.5 {
            return (false, "控件越出状态条:\(view.frame)")
        }
        // ...the status text clear of the slider...
        guard status.frame.maxX <= slider.frame.minX else {
            return (false, "状态文字与滑块重叠 \(status.frame.maxX - slider.frame.minX) pt")
        }
        // ...and still given most of the row. The two are laid out from opposite
        // edges: the control takes the width it needs on the right and the text
        // gets what is left. A control parked on the left instead would leave the
        // status label no width at all — the text would vanish, which a check
        // that only compares the two frames' edges would happily accept.
        guard status.frame.width > width * 0.4 else {
            return (false, "状态文字只剩 \(Int(status.frame.width)) pt")
        }
        // ...and the slider actually reachable, not covered by the label above
        // it. A drag on the knob has to reach the slider: `window` would swallow
        // it otherwise, and the control would look present but do nothing.
        let hit = window.contentView?
            .hitTest(slider.convert(NSPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: nil))
        guard hit === slider else { return (false, "滑块被别的视图挡住") }

        // Hidden — every tool with no parameter of its own — it must take no
        // width: the status line gets the row back, and a hidden control that
        // still reserved 190pt would leave the status text truncated for nothing.
        let shownStatusWidth = status.frame.width
        bar.setParameter(nil, value: 0)
        bar.layoutSubtreeIfNeeded()
        guard slider.isHidden else { return (false, "隐藏后滑块仍在显示") }
        guard status.frame.width > shownStatusWidth + 100 else {
            return (false, "隐藏后状态文字只多出 \(Int(status.frame.width - shownStatusWidth)) pt")
        }
        return (true, "滑块 \(Int(slider.frame.width))pt · 状态文字 \(Int(shownStatusWidth))→\(Int(status.frame.width))pt")
    }

    /// The slider in the strip and the canvas that honours the number have to
    /// agree on the range, and moving the slider has to reach the canvas — for
    /// every parameter, not just the one it started life as.
    ///
    /// Two separate mistakes this catches: a control offering travel the canvas
    /// clamps away (the knob moves and the number does not), and a control wired
    /// to nothing (the knob moves and nothing at all happens). Both look like a
    /// working control in a screenshot. Both ends and the middle are driven,
    /// because a knob wired to a constant passes a check that only moves it once.
    private static func parameterSliderDrivesTheCanvas() -> (passed: Bool, detail: String) {
        let bar = InfoBarView(frame: NSRect(x: 0, y: 0, width: 900,
                                            height: MainLayout.infoBarHeight))
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let probe = ParameterProbe()
        probe.canvas = canvas
        bar.delegate = probe
        guard let slider = bar.subviews.compactMap({ $0 as? NSSlider }).first else {
            return (false, "状态条里没有滑块")
        }

        var problems: [String] = []
        var driven = 0
        for parameter in ToolParameter.allCases {
            bar.setParameter(parameter, value: canvas.value(of: parameter))
            bar.layoutSubtreeIfNeeded()

            let range = parameter.range
            guard slider.minValue == range.lowerBound, slider.maxValue == range.upperBound else {
                problems.append(String(format: "%@ 滑块 %.4g–%.4g 应为 %.4g–%.4g", "\(parameter)",
                                       slider.minValue, slider.maxValue,
                                       range.lowerBound, range.upperBound))
                continue
            }
            if slider.isHidden { problems.append("\(parameter) 下滑块没有出现"); continue }

            let mid = ((range.lowerBound + range.upperBound) / 2).rounded()
            for target in [range.lowerBound, mid, range.upperBound] {
                slider.doubleValue = target
                _ = slider.sendAction(slider.action, to: slider.target)
                let landed = canvas.value(of: parameter)
                if landed != target {
                    problems.append(String(format: "%@ 拖到 %.4g 只到 %.4g", "\(parameter)", target, landed))
                }
                driven += 1
            }

            // The readout follows the canvas, both ways: the `[` `]` keys move
            // the radius without touching the slider, so the strip has to be
            // told — and told what the canvas settled on, not what was asked.
            canvas.setValue(parameter.range.lowerBound, of: parameter)
            bar.updateParameter(value: canvas.value(of: parameter))
            let label = bar.subviews.compactMap { $0 as? NSTextField }
                .first { !$0.isHidden && !$0.stringValue.isEmpty }?.stringValue ?? ""
            let expected = parameter.readout(parameter.range.lowerBound)
            if label != expected { problems.append("\(parameter) 读数是「\(label)」应为「\(expected)」") }
        }

        // The widest reading any of the ranges can produce has to fit the width
        // reserved for it: clipped, the number that justifies the whole control
        // reads as 「半径 1」 and the user cannot tell 120 from 12.
        var widest = 0.0
        var widestText = ""
        for parameter in ToolParameter.allCases {
            let range = parameter.range
            for end in [range.lowerBound, range.upperBound] {
                let text = parameter.readout(end)
                let width = (text as NSString)
                    .size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11,
                                                                                  weight: .regular)]).width
                if width > widest { widest = width; widestText = text }
            }
        }
        if widest > ToolbarView.parameterLabelWidth - 2 {
            problems.append(String(format: "读数「%@」占 %.0fpt,只给了 %.0fpt",
                                   widestText, widest, ToolbarView.parameterLabelWidth))
        }

        let passed = problems.isEmpty
        return (passed, passed
            ? "\(ToolParameter.allCases.count) 个参数 × 两端与中点共 \(driven) 次拖动全部落到画布 · 最宽读数「\(widestText)」\(Int(widest))pt/\(Int(ToolbarView.parameterLabelWidth))pt"
            : problems.joined(separator: ";"))
    }

    /// Does what the app does with the slider's news, and nothing else: the
    /// conversion itself lives on the canvas so there is no second copy of it to
    /// drift.
    private final class ParameterProbe: InfoBarDelegate {
        weak var canvas: CanvasView?
        func infoBar(_ infoBar: InfoBarView, didSetParameter parameter: ToolParameter, to value: Double) {
            guard let canvas else { return }
            canvas.setValue(value, of: parameter)
            infoBar.updateParameter(value: canvas.value(of: parameter))
        }
    }

    /// The strip must show the parameter the tool in hand owns, and the tools
    /// that own none must leave the strip to the status text.
    ///
    /// This is the fix itself. 区域取点 and 自动跟踪 used to be shipped with no
    /// visible setting — the grid spacing behind a modal dialog in 操作 and the
    /// trace density not adjustable at all — so the mapping from tool to number
    /// is the thing that has to hold. A control showing the *wrong* tool's number
    /// is worse than none: the user moves it and something else changes.
    private static func parameterControlFollowsTheTool() -> (passed: Bool, detail: String) {
        // The canvas' own ring predicate has to agree with the mapping, or the
        // circle is drawn under one tool while the slider sizes it under another.
        for tool in ToolMode.allCases where tool.usesRing != (tool.parameter == .ringRadius) {
            return (false, "\(tool):usesRing=\(tool.usesRing) parameter=\(String(describing: tool.parameter))")
        }
        // And every tool that takes points has to have a number to tune.
        let takers: Set<ToolMode> = [.gridDigitize, .traceDigitize, .redigitize,
                                     .symbolMatch, .eraser, .reorder]
        let without = ToolMode.allCases.filter { takers.contains($0) && $0.parameter == nil }
        guard without.isEmpty else {
            return (false, "取点工具没有可调参数:\(without.map { "\($0)" }.sorted())")
        }
        // The two point-taking routes must not borrow the same number by
        // accident: 区域取点 and 自动跟踪 space *different* samplings, and wiring
        // both to one of them would leave the other unadjustable again.
        guard ToolMode.gridDigitize.parameter == .gridSpacing,
              ToolMode.traceDigitize.parameter == .traceSpacing,
              ToolMode.redigitize.parameter == .gridSpacing
        else { return (false, "区域取点/重新选点/自动跟踪 的参数映射不对") }
        // Every parameter in the enum has to be reachable, or the control it was
        // added for is dead code that no tool ever shows.
        let reachable = Set(ToolMode.allCases.compactMap(\.parameter))
        guard reachable.count == ToolParameter.allCases.count else {
            return (false, "有工具从没显示过的参数:\(Set(ToolParameter.allCases).subtracting(reachable))")
        }

        let bar = InfoBarView(frame: NSRect(x: 0, y: 0, width: 900,
                                            height: MainLayout.infoBarHeight))
        bar.update(step: "", status: "", lineSummary: "")
        for tool in ToolMode.allCases {
            bar.setParameter(tool.parameter, value: tool.parameter?.range.lowerBound ?? 0)
            bar.layoutSubtreeIfNeeded()
            let slider = bar.subviews.compactMap { $0 as? NSSlider }.first
            // With step and status empty, the only non-empty label in the bar is
            // the readout, so it is identified by what it says rather than by its
            // position among the labels.
            let label = bar.subviews.compactMap { $0 as? NSTextField }
                .first { !$0.isHidden && !$0.stringValue.isEmpty }?.stringValue ?? ""
            guard let parameter = tool.parameter else {
                if slider?.isHidden == false || !label.isEmpty {
                    return (false, "\(tool) 不该显示参数控件,却显示「\(label)」")
                }
                continue
            }
            guard slider?.isHidden == false else { return (false, "\(tool) 下参数控件没有出现") }
            let expected = parameter.readout(parameter.range.lowerBound)
            guard label == expected else {
                return (false, "\(tool) 读数「\(label)」应为「\(expected)」")
            }
        }
        let hidden = ToolMode.allCases.filter { $0.parameter == nil }.count
        return (true, "\(ToolMode.allCases.count - hidden) 个工具显示自己的参数 · \(hidden) 个不显示 · \(ToolParameter.allCases.count) 种参数各有归属")
    }

    /// The defaults live in two places that cannot see each other — the app's
    /// constants and `ProjectState`'s initialiser — and a first run that opens at
    /// a different spacing from the one the slider shows is the kind of mismatch
    /// nobody notices until the points come out wrong.
    private static func spacingDefaultsMatchTheModel() -> (passed: Bool, detail: String) {
        let fresh = ProjectState()
        let passed = fresh.gridSpacing == CanvasView.gridSpacingDefault
            && fresh.traceSpacing == CanvasView.traceSpacingDefault
            && CanvasView.gridSpacingRange.contains(fresh.gridSpacing)
            && CanvasView.traceSpacingRange.contains(fresh.traceSpacing)
            && ToolParameter.gridSpacing.range == Double(CanvasView.gridSpacingRange.lowerBound)...Double(CanvasView.gridSpacingRange.upperBound)
            && ToolParameter.traceSpacing.range == Double(CanvasView.traceSpacingRange.lowerBound)...Double(CanvasView.traceSpacingRange.upperBound)
        return (passed, passed
            ? "初值 网格 \(fresh.gridSpacing) / 跟踪 \(fresh.traceSpacing),范围 \(CanvasView.gridSpacingRange) 与 \(CanvasView.traceSpacingRange)"
            : "模型 网格 \(fresh.gridSpacing) / 跟踪 \(fresh.traceSpacing);控件默认 \(CanvasView.gridSpacingDefault) / \(CanvasView.traceSpacingDefault),范围 \(CanvasView.gridSpacingRange) / \(CanvasView.traceSpacingRange)")
    }

    /// 网格间距 has to reach the scan, and reach it as the spacing the user
    /// chose — not merely be stored.
    ///
    /// The scan's columns land on `x0, x0+dx, x0+2dx…`, so the greatest common
    /// divisor of the gaps between the columns it found *is* `dx` whenever the
    /// curve spans the region. That is read off the points that came out, which
    /// is the only place the wiring shows: asserting `state.gridSpacing == 12`
    /// would pass for a control connected to the field and not to the digitizer.
    ///
    /// 12 and 3 rather than the default 8 and something else, so a run that
    /// silently used the default fails instead of passing.
    private static func gridSpacingDecidesThePointCount() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas(), let buffer = probe.canvas.buffer else {
            return (false, "无法构建画布")
        }
        let canvas = probe.canvas
        let width = Double(buffer.width), height = Double(buffer.height)

        /// Sweeps the whole image with the area tool, through the same mouse
        /// events the user's drag produces.
        func sweep(at spacing: Int) -> [PixelPoint]? {
            canvas.clearPoints(of: probe.id)
            canvas.setGridSpacing(spacing)
            canvas.tool = .gridDigitize
            canvas.selectLine(id: probe.id)
            guard let down = dragEvent(canvas, .leftMouseDown, CGPoint(x: 2, y: 2)),
                  let drag = dragEvent(canvas, .leftMouseDragged,
                                       CGPoint(x: width - 2, y: height - 2)),
                  let up = dragEvent(canvas, .leftMouseUp,
                                     CGPoint(x: width - 2, y: height - 2))
            else { return nil }
            canvas.mouseDown(with: down)
            canvas.mouseDragged(with: drag)
            canvas.mouseUp(with: up)
            let points = canvas.state.lines.first(where: { $0.id == probe.id })?.points
            return (points?.isEmpty ?? true) ? nil : points
        }

        /// The grid the columns of `points` fall on.
        func columnGrid(_ points: [PixelPoint]) -> Int {
            let columns = Set(points.map { Int($0.x.rounded()) }).sorted()
            guard columns.count >= 2 else { return 0 }
            return zip(columns, columns.dropFirst())
                .reduce(0) { running, pair in gcd(running, pair.1 - pair.0) }
        }

        guard let coarse = sweep(at: 12), let fine = sweep(at: 3) else {
            return (false, "两次扫描都没出点")
        }
        let coarseGrid = columnGrid(coarse), fineGrid = columnGrid(fine)
        let densified = fine.count > coarse.count * 2
        let passed = coarseGrid == 12 && fineGrid == 3 && densified
        return (passed, passed
            ? "列间距 12 → \(coarse.count) 点(实测格 \(coarseGrid));间距 3 → \(fine.count) 点(实测格 \(fineGrid))"
            : "列间距 12 → \(coarse.count) 点(实测格 \(coarseGrid),应为 12);"
              + "间距 3 → \(fine.count) 点(实测格 \(fineGrid),应为 3)")
    }

    /// 取点密度 retunes the auto trace: the same route, sampled less often.
    ///
    /// Three facts, and each rules out a different way of getting it wrong. The
    /// kept points must all be points the walk itself produced — an interpolating
    /// thinning would put points between pixels, off the curve, and look right in
    /// a screenshot. The first and last must survive — a thinned curve that stops
    /// short of where the trace stopped is a curve with a missing end. And
    /// consecutive kept points must be at least the spacing apart, which is the
    /// knob's whole meaning and fails if the number reaches the model and not the
    /// pass.
    private static func traceSpacingThinsTheTracedCurve() -> (passed: Bool, detail: String) {
        guard let probe = singleCurveCanvas(),
              let seeded = probe.canvas.state.lines.first(where: { $0.id == probe.id }),
              let seed = seeded.points.min(by: { $0.x < $1.x }) else {
            return (false, "无法构建画布")
        }
        let canvas = probe.canvas

        /// Traces from the same seed with the spacing the strip would be showing.
        func trace(at spacing: Int) -> [PixelPoint]? {
            canvas.clearPoints(of: probe.id)
            canvas.setTraceSpacing(spacing)
            canvas.tool = .traceDigitize
            canvas.selectLine(id: probe.id)
            guard let click = dragEvent(canvas, .leftMouseDown, CGPoint(x: seed.x, y: seed.y))
            else { return nil }
            canvas.mouseDown(with: click)
            let points = canvas.state.lines.first(where: { $0.id == probe.id })?.points
            return (points?.isEmpty ?? true) ? nil : points
        }

        guard let dense = trace(at: 1), let sparse = trace(at: 8) else {
            return (false, "跟踪没有出点")
        }
        let walked = Set(dense)
        let invented = sparse.filter { !walked.contains($0) }
        let keptEnds = sparse.first == dense.first && sparse.last == dense.last
        let ratio = Double(dense.count) / Double(max(sparse.count, 1))
        let thinned = ratio > 4 && sparse.count >= 4
        // Every gap but the last: the end point is appended whether or not it is
        // a whole spacing from its predecessor, which is the one deliberate
        // exception to the rule.
        let gaps = zip(sparse, sparse.dropFirst()).dropLast()
            .map { hypot($1.x - $0.x, $1.y - $0.y) }
        let honoured = !gaps.isEmpty && gaps.allSatisfy { $0 >= 8 - 1e-9 }
        let passed = invented.isEmpty && keptEnds && thinned && honoured
        return (passed, passed
            ? "每 1px → \(dense.count) 点,每 8px → \(sparse.count) 点(抽稀 \(String(format: "%.1f", ratio))×),端点一致,最小间隔 \(String(format: "%.1f", gaps.min() ?? 0))px"
            : "每 1px → \(dense.count) 点,每 8px → \(sparse.count) 点;"
              + "凭空造点 \(invented.count);端点 \(keptEnds ? "一致" : "不一致");"
              + "最小间隔 \(String(format: "%.1f", gaps.min() ?? 0))px")
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    /// 5×5 box blur — an anti-aliased edge, for a fixture that draws hard ones.
    ///
    /// `SyntheticChart` fills solid discs, so every pixel of a synthetic stroke
    /// is either the pure colour or the pure background; a real screenshot has a
    /// ramp between the two. Anything about edge behaviour — and the reported
    /// cross-curve leak lived entirely on that ramp — cannot be reproduced
    /// without this. Radius 2 rather than 1 because a box blur's coverage steps
    /// are `1/(2r+1)²` apart, and the ramp has to reach the last coverage the
    /// distance gate still admits.
    private static func softened(_ buffer: BitmapBuffer, radius: Int = 2) -> BitmapBuffer {
        var out = [UInt8](repeating: 0, count: buffer.width * buffer.height * 3)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                var sums = (0, 0, 0), n = 0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let sx = x + dx, sy = y + dy
                        guard sx >= 0, sx < buffer.width, sy >= 0, sy < buffer.height else { continue }
                        let c = buffer.color(atX: sx, y: sy)
                        sums = (sums.0 + Int(c.r), sums.1 + Int(c.g), sums.2 + Int(c.b))
                        n += 1
                    }
                }
                let i = (y * buffer.width + x) * 3
                out[i] = UInt8(sums.0 / n)
                out[i + 1] = UInt8(sums.1 / n)
                out[i + 2] = UInt8(sums.2 / n)
            }
        }
        return BitmapBuffer(width: buffer.width, height: buffer.height, pixels: out)
    }

    /// The panel's three cards (curves / order / points) must stack with no gap
    /// tall enough to read as a hole, the curve list must stay a fixed band rather
    /// than swelling with the window, and the point card must reach the bottom.
    /// The panel used to size the top band from the window height, which in a tall
    /// window left an empty white strip above the data and squeezed the table.
    private static func sidebarBandsAreTight() -> Bool {
        var tight = true
        for height in [420.0, 700.0, 1_200.0] {
            let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 264, height: height))
            var line = CurveLine(name: "曲线 1", color: RGB8(r: 200, g: 40, b: 90))
            for x in 0..<20 { line.points.append(PixelPoint(x: Double(x) * 8, y: Double(x) * 5)) }
            sidebar.update(lines: [line], calibration: nil, activeID: line.id)
            sidebar.layoutSubtreeIfNeeded()

            // The cards, not the labels inside them: the gap between two cards is
            // what reads as a hole.
            let cards = sidebar.subviews
                .filter { String(describing: type(of: $0)) == "CardView" }
                .map(\.frame).sorted { $0.minY < $1.minY }
            guard cards.count == 3 else { tight = false; break }
            guard let first = cards.first, let last = cards.last else { tight = false; break }

            // Nothing above the first card or past the bottom of the panel.
            if first.minY > 16 || last.maxY > height + 0.5 { tight = false; break }

            // Walk top to bottom; any gap wider than `gap` plus a point is a hole.
            var cursor = 0.0
            for rect in cards {
                if rect.minY - cursor > 12 { tight = false; break }
                cursor = max(cursor, rect.maxY)
            }
            if !tight { break }

            let tables = descendants(of: sidebar).compactMap { $0 as? NSTableView }
            guard let curveTable = tables.first(where: { $0.numberOfColumns == 1 }),
                  let curveScroll = curveTable.enclosingScrollView,
                  let pointScroll = tables.first(where: { $0.numberOfColumns == 3 })?
                      .enclosingScrollView else { tight = false; break }

            // The curve list is a fixed band. Growing it with the window is the
            // exact thing that produced the dead strip the user objected to.
            if curveScroll.frame.height > 120 { tight = false; break }

            // The data card reaches the bottom of the panel, so the column reads
            // as three deliberate sections rather than a hole and then a table.
            if last.maxY < height - 10 { tight = false; break }
            if pointScroll.frame.height < 0.25 * height { tight = false; break }
        }
        return tight
    }

    /// Every descendant of `view`, depth first, so a check does not have to know
    /// how many layers of containers the panel has grown.
    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// The panel must read as a grey work area carrying white cards, not as one
    /// flat white sheet. The user's complaint was precisely that grey and white
    /// met with no boundary — a white panel passes every geometric check above,
    /// so only a render can tell the two apart.
    ///
    /// Four probes: the field the cards sit on, a card's own body, the card's
    /// header band, and the run of points across the field/card seam. The field
    /// must be grey rather than white, the body white, the header a shade darker
    /// than the body, and the seam must carry a rule darker than both sides — an
    /// abrupt grey-meets-white edge is the thing that looked wrong, and only the
    /// pixels can distinguish it from a drawn border.
    private static func sidebarPanelIsTinted() -> (passed: Bool, detail: String) {
        var line = CurveLine(name: "曲线 1", color: RGB8(r: 200, g: 40, b: 90))
        for x in 0..<20 { line.points.append(PixelPoint(x: Double(x) * 8, y: Double(x) * 5)) }
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 264, height: 700))
        sidebar.update(lines: [line], calibration: nil, activeID: line.id)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.displayIfNeeded()
        guard let rep = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) else {
            return (false, "无法渲染面板")
        }
        sidebar.cacheDisplay(in: sidebar.bounds, to: rep)

        let sx = CGFloat(rep.pixelsWide) / sidebar.bounds.width
        let sy = CGFloat(rep.pixelsHigh) / sidebar.bounds.height

        /// Mean channel value at one panel point, or nil outside the render.
        func level(_ x: Double, _ y: Double) -> Double? {
            let px = Int((x * sx).rounded()), py = Int((y * sy).rounded())
            guard px >= 0, px < rep.pixelsWide, py >= 0, py < rep.pixelsHigh,
                  let c = rep.colorAt(x: px, y: py) else { return nil }
            return (Double(c.redComponent) + Double(c.greenComponent) + Double(c.blueComponent)) / 3
        }

        let cards = descendants(of: sidebar)
            .filter { String(describing: type(of: $0)) == "CardView" }
            .map { $0.convert($0.bounds, to: sidebar) }
            .sorted { $0.minY < $1.minY }
        guard let card = cards.first else { return (false, "面板里没有卡片") }

        // The 8pt field on the card's left, the card's own body inset just inside
        // its border, its header band, and a sweep across the seam between them.
        guard let field = level(card.minX - 4, card.midY),
              let body = level(card.minX + 3, card.midY),
              let header = level(card.midX, card.minY + 10) else {
            return (false, "取不到面板像素")
        }
        var seam: Double?
        var x = card.minX - 4
        while x <= card.minX + 4 {
            if let v = level(x, card.midY) { seam = min(seam ?? v, v) }
            x += 0.25
        }
        guard let seam else { return (false, "取不到卡片边框") }

        let fieldIsGrey = field >= 0.78 && field <= 0.965
        let bodyIsWhite = body >= 0.95
        let headerIsDarker = header <= body - 0.05
        let seamIsDrawn = seam <= min(field, body) - 0.06

        let detail = String(format: "底色 %.3f · 卡片 %.3f · 标题 %.3f · 边框 %.3f",
                            field, body, header, seam)

        // The same panel under darkAqua must not be the light panel with dark
        // tables dropped in: the field, the header band and the card outline
        // were all fixed greys once, which read as a light frame around black
        // cards. Dark layering runs the other way — the body sinks, the field
        // and the header band float — so the assertions are ordered, not
        // absolute: body darkest, then field, then header, with a visible edge.
        sidebar.appearance = NSAppearance(named: .darkAqua)
        sidebar.needsDisplay = true
        sidebar.displayIfNeeded()
        guard let darkRep = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds)
        else { return (false, "无法渲染深色面板") }
        sidebar.cacheDisplay(in: sidebar.bounds, to: darkRep)

        let dsx = CGFloat(darkRep.pixelsWide) / sidebar.bounds.width
        let dsy = CGFloat(darkRep.pixelsHigh) / sidebar.bounds.height
        func darkLevel(_ x: Double, _ y: Double) -> Double? {
            let px = Int((x * dsx).rounded()), py = Int((y * dsy).rounded())
            guard px >= 0, px < darkRep.pixelsWide, py >= 0, py < darkRep.pixelsHigh,
                  let c = darkRep.colorAt(x: px, y: py) else { return nil }
            return (Double(c.redComponent) + Double(c.greenComponent) + Double(c.blueComponent)) / 3
        }
        guard let dField = darkLevel(card.minX - 4, card.midY),
              let dBody = darkLevel(card.minX + 3, card.midY),
              let dHeader = darkLevel(card.midX, card.minY + 10) else {
            return (false, "取不到深色面板像素")
        }
        var dSeam: Double?
        x = card.minX - 4
        while x <= card.minX + 4 {
            if let v = darkLevel(x, card.midY) { dSeam = max(dSeam ?? v, v) }
            x += 0.25
        }
        guard let dSeam else { return (false, "取不到深色卡片边框") }
        sidebar.appearance = nil

        let darkIsDark = dField < 0.5 && dBody < 0.5 && dHeader < 0.5
        let darkLayers = dBody < dField && dHeader > dBody
        let darkSeamDrawn = dSeam >= max(dField, dBody) + 0.05
        let lightOK = fieldIsGrey && bodyIsWhite && headerIsDarker && seamIsDrawn
        let darkOK = darkIsDark && darkLayers && darkSeamDrawn
        let darkDetail = String(format: "深色: 底色 %.3f · 卡片 %.3f · 标题 %.3f · 边框 %.3f",
                                dField, dBody, dHeader, dSeam)
        return (lightOK && darkOK, detail + " · " + darkDetail)
    }

    /// The toolbar and the info bar must read as window chrome in *both*
    /// appearances. Each once captured `windowBackgroundColor` into a `CGColor`
    /// at build time — frozen at whatever the system started in, so under dark
    /// mode the bars stayed light while their (adaptive) text went light too,
    /// and the strip read as blank paper. The bars draw their fill now, so the
    /// pixels are probed under both appearances: bright under aqua, dark under
    /// darkAqua, and never the same.
    private static func chromeFollowsAppearance() -> (passed: Bool, detail: String) {
        func background(of view: NSView, under name: NSAppearance.Name) -> Double? {
            view.appearance = NSAppearance(named: name)
            view.needsDisplay = true
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return nil
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            let sx = CGFloat(rep.pixelsWide) / view.bounds.width
            let sy = CGFloat(rep.pixelsHigh) / view.bounds.height
            // The far right end: past every button and label, pure background.
            let px = Int(((view.bounds.width - 12) * sx).rounded())
            let py = Int((view.bounds.midY * sy).rounded())
            guard let c = rep.colorAt(x: px, y: py) else { return nil }
            return (Double(c.redComponent) + Double(c.greenComponent) + Double(c.blueComponent)) / 3
        }

        var values: [(String, Double, Double)] = []
        for (name, view) in [("工具栏", ToolbarView(frame: NSRect(x: 0, y: 0, width: 1_300,
                                                                  height: 52)) as NSView),
                             ("信息条", InfoBarView(frame: NSRect(x: 0, y: 0, width: 1_300,
                                                                  height: 52)))] {
            guard let light = background(of: view, under: .aqua),
                  let dark = background(of: view, under: .darkAqua) else {
                return (false, "\(name)渲染不出来")
            }
            values.append((name, light, dark))
        }
        let passed = values.allSatisfy { $0.1 > 0.8 && $0.2 < 0.5 }
        let detail = values.map { "\($0.0) 浅 \(String(format: "%.3f", $0.1)) · 深 \(String(format: "%.3f", $0.2))" }
            .joined(separator: "; ")
        return (passed, detail)
    }

    /// The tables must not be wider than their scroll views' clip — the real
    /// overflow condition, learned the hard way: an earlier check summed
    /// *column widths* against the clip and passed while the table's actual
    /// frame stuck out by 32pt (the scroller reservation NSTableView adds on
    /// top of the columns), which is why the point counts stayed half outside
    /// the panel even after the "fix". Assert the frame, not the arithmetic.
    private static func curveListFitsWithoutHorizontalScrolling()
        -> (passed: Bool, detail: String) {
        var lines: [CurveLine] = []
        for i in 1...5 {
            var line = CurveLine(name: "曲线 \(i)", color: RGB8(r: 200, g: 40, b: 90))
            for x in 0..<7 { line.points.append(PixelPoint(x: Double(x), y: Double(x))) }
            lines.append(line)
        }
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 264, height: 700))
        sidebar.update(lines: lines, calibration: nil, activeID: lines[3].id)
        sidebar.layoutSubtreeIfNeeded()

        let scrolls = descendants(of: sidebar).compactMap { $0 as? NSScrollView }
        var parts: [String] = []
        var ok = true
        for (label, columns) in [("曲线列表", 1), ("点表", 3)] {
            guard let table = scrolls.compactMap({ $0.documentView as? NSTableView })
                .first(where: { $0.numberOfColumns == columns }),
                  let scroll = table.enclosingScrollView else {
                return (false, "找不到\(label)的滚动区")
            }
            let clip = scroll.contentSize.width
            let frame = table.frame.width
            parts.append("\(label) 表 \(String(format: "%.1f", frame))"
                         + " / 可见区 \(String(format: "%.1f", clip))")
            if frame > clip + 0.5 { ok = false }
        }
        return (ok, parts.joined(separator: "; "))
    }

    /// "Excel-style", as the user put it: every row separated by a rule and every
    /// column divided, so the numbers read as a grid instead of floating on white.
    /// Asserting `gridStyleMask` alone would not catch the rules failing to reach
    /// the screen, so the panel is rendered and the pixels measured: a divider is
    /// an x where the ink runs down most of the table's height, a row rule a y
    /// where it runs across most of its width. Dropping the mask or the dividers
    /// each send the count to zero, so the check fails if either kind goes missing.
    private static func pointTableDrawsGrid() -> Bool {
        var line = CurveLine(name: "曲线 1", color: RGB8(r: 200, g: 40, b: 90))
        for x in 0..<30 { line.points.append(PixelPoint(x: Double(x) * 8, y: Double(x) * 5)) }
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 264, height: 700))
        sidebar.update(lines: [line], calibration: nil, activeID: line.id)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.displayIfNeeded()
        guard let rep = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) else {
            return false
        }
        sidebar.cacheDisplay(in: sidebar.bounds, to: rep)
        guard let scroll = descendants(of: sidebar).compactMap({ $0 as? NSScrollView })
            .first(where: { ($0.documentView as? NSTableView)?.numberOfColumns == 3 }),
            let table = scroll.documentView as? NSTableView else { return false }

        let sx = CGFloat(rep.pixelsWide) / sidebar.bounds.width
        let sy = CGFloat(rep.pixelsHigh) / sidebar.bounds.height
        // The table now lives inside a card, so its frame is in the card's
        // coordinates. Convert to the panel's, which is what the render covers.
        let scrollFrame = scroll.convert(scroll.bounds, to: sidebar)
        let headerHeight = table.headerView?.frame.height ?? 0
        let top = scrollFrame.minY + 1 + headerHeight
        let bottom = scrollFrame.maxY - 1
        let left = scrollFrame.minX + 1
        // Ink ends where the *columns* end, not where the scroll view does:
        // under legacy scrollers the table reserves room for the vertical
        // scroller between the last column and the clip's edge, and the grid
        // honestly does not cover it.
        let right = scrollFrame.minX + table.rect(ofColumn: table.numberOfColumns - 1).maxX
        let interiorHeight = bottom - top
        guard interiorHeight > 0, right > left else { return false }

        func isInk(_ x: Double, _ y: Double) -> Bool {
            let px = Int((x * sx).rounded()), py = Int((y * sy).rounded())
            guard px >= 0, px < rep.pixelsWide, py >= 0, py < rep.pixelsHigh,
                  let c = rep.colorAt(x: px, y: py) else { return false }
            return Int((c.redComponent * 255).rounded()) < 245
                || Int((c.greenComponent * 255).rounded()) < 245
                || Int((c.blueComponent * 255).rounded()) < 245
        }

        // A column divider: a 1pt rule, so require ink down most of the height
        // over a run of consecutive x, and count the run once.
        var dividerColumns = 0
        var runLength = 0
        var x = left + 2
        while x < right - 2 {
            var hit = 0, total = 0
            var y = top + 2
            while y < bottom - 2 { total += 1; if isInk(x, y) { hit += 1 }; y += 0.5 }
            if total > 0 && Double(hit) / Double(total) >= 0.70 {
                if runLength == 0 { dividerColumns += 1 }
                runLength += 1
            } else {
                runLength = 0
            }
            x += 0.5
        }

        // A row rule: ink across at least 90% of the table's inner width.
        var ruleRows = 0
        var y = top + 1
        while y < bottom - 1 {
            var hit = 0, total = 0
            var px = left
            while px < right { total += 1; if isInk(px, y) { hit += 1 }; px += 1 }
            if total > 0 && Double(hit) / Double(total) >= 0.90 { ruleRows += 1; y += 1 }
            y += 0.5
        }

        // #/X/Y means two column dividers, and one rule per visible row.
        let visibleRows = Int(interiorHeight / table.rowHeight)
        return dividerColumns >= 2 && ruleRows >= Int(Double(visibleRows) * 0.7)
    }

/// A stand-in for AppDelegate's panel wiring: it answers a curve selection the
/// way the app does — select on the canvas, then rebuild the panel — and counts
/// the round trips so a re-entrant selection loop shows up as a number instead
/// of a stack overflow.
private final class SelectionLoopProbe: SidebarViewDelegate {
    weak var panel: SidebarView?
    var lines: [CurveLine] = []
    var roundTrips = 0

    func sidebar(_ sidebar: SidebarView, didSelectLine id: UUID) {
        roundTrips += 1
        // Stop well short of the stack limit: with the guard missing the loop
        // recurses hundreds deep and dies before any bound set here would be
        // reached, so the cap has to be low enough for the check to report a
        // number instead of taking the whole selftest down with it.
        guard roundTrips <= 40 else { return }
        sidebar.update(lines: lines, calibration: nil, activeID: id)
    }
    func sidebar(_ s: SidebarView, didSetOrder o: PointOrder, for id: UUID) {}
    func sidebar(_ s: SidebarView, didSetVisible v: Bool, for id: UUID) {}
    func sidebar(_ s: SidebarView, didRenameLine id: UUID, to name: String) {}
    func sidebarDidRequestAddLine(_ s: SidebarView) {}
    func sidebar(_ s: SidebarView, didRequestRemoveLine id: UUID) {}
    // Not exercised here: this probe exists to count selection round trips, and
    // the table's editing path is driven directly in the selftest's own check.
    func sidebar(_ s: SidebarView, didEditPointAt row: Int,
                 axis: PointCoordinate, to value: Double) -> Bool { false }
    func sidebar(_ s: SidebarView, didRequestRemovePointAt row: Int) {}
}

/// A stand-in for the window's panel wiring: it answers a typed coordinate the
/// way the app does — hand it to the canvas, report whether it was taken — and
/// counts the calls, so a panel that parsed the text but never asked anybody is
/// distinguishable from one that did.
private final class PointEditProbe: SidebarViewDelegate {
    private let canvas: CanvasView
    private(set) var edits = 0

    init(canvas: CanvasView) { self.canvas = canvas }

    func sidebar(_ sidebar: SidebarView, didEditPointAt row: Int,
                 axis: PointCoordinate, to value: Double) -> Bool {
        edits += 1
        return canvas.setCoordinate(value, of: axis, atDisplayIndex: row)
    }

    func sidebar(_ sidebar: SidebarView, didRequestRemovePointAt row: Int) {
        _ = canvas.removePoint(atDisplayIndex: row)
    }

    func sidebar(_ sidebar: SidebarView, didSelectLine id: UUID) {}
    func sidebar(_ sidebar: SidebarView, didSetOrder order: PointOrder, for id: UUID) {}
    func sidebar(_ sidebar: SidebarView, didSetVisible visible: Bool, for id: UUID) {}
    func sidebar(_ sidebar: SidebarView, didRenameLine id: UUID, to name: String) {}
    func sidebarDidRequestAddLine(_ sidebar: SidebarView) {}
    func sidebar(_ sidebar: SidebarView, didRequestRemoveLine id: UUID) {}
}

    private static func yErrors(_ extracted: [PixelPoint], chart: SyntheticChart.Chart) -> [Double] {
        let map = chart.calibration
        let truth = chart.curvePixels
        let span = chart.isLogY
            ? log10(chart.yMaxValue) - log10(chart.yMinValue)
            : chart.yMaxValue - chart.yMinValue

        return extracted.map { p in
            var bestIndex = 0
            var bestDistance = Double.infinity
            for (i, t) in truth.enumerated() {
                let d = abs(t.x - p.x)
                if d < bestDistance { bestDistance = d; bestIndex = i }
            }
            let trueY = truth[bestIndex].y
            guard let extractedValue = try? map.y.value(atPixel: p.y),
                  let trueValue = try? map.y.value(atPixel: trueY) else { return .nan }
            if chart.isLogY {
                return abs(log10(extractedValue) - log10(trueValue)) / span
            }
            return abs(extractedValue - trueValue) / span
        }
    }

    /// Per-curve error against that curve's own ground truth, normalised by the
    /// value axis' span so it reads as a percentage.
    private static func multiYErrors(_ extracted: [PixelPoint],
                                     truth: [PixelPoint],
                                     map: CalibrationMap) -> [Double] {
        let range = abs(map.y.valueMax - map.y.valueMin)
        return extracted.map { p in
            var bestIndex = 0
            var bestDistance = Double.infinity
            for (i, t) in truth.enumerated() {
                let d = abs(t.x - p.x)
                if d < bestDistance { bestDistance = d; bestIndex = i }
            }
            guard let extractedValue = try? map.y.value(atPixel: p.y),
                  let trueValue = try? map.y.value(atPixel: truth[bestIndex].y) else { return .nan }
            return abs(extractedValue - trueValue) / range
        }
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let rank = p / 100 * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down)), upper = Int(rank.rounded(.up))
        if lower == upper { return sorted[lower] }
        let frac = rank - Double(lower)
        return sorted[lower] * (1 - frac) + sorted[upper] * frac
    }
}
