import AppKit
import GDCore

/// Target/action trampoline so a checkbox inside an `NSAlert` accessory view can
/// run a closure — the alert sheet has no controller to own the action.
private final class ClosureTarget: NSObject {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire(_ sender: Any?) { body() }
}

private var logTrampolineKey: UInt8 = 0

/// Collects the values for the four clicked anchors — X start, X end, Y start,
/// Y end — and installs the resulting coordinate system (FR-2.1 – FR-2.3).
///
/// Four points, not three, because the two axes need not meet: a chart drawn as
/// an X rule along the bottom and a Y rule up the left, neither reaching the
/// other, is common, and a shared origin cannot describe it.
///
/// The sheet asks for four numbers in two rows — one row per axis — because the
/// axis is the unit the user thinks in and each axis' two ends belong together.
/// Direction comes from the clicked pixels, never from the typing order: each
/// axis reads only its own component from its two anchors, so an axis drawn
/// right-to-left or bottom-to-top maps correctly without a "reverse" switch.
///
/// The same sheet serves both entry points: first-time calibration (anchors
/// from four clicks) and editing the numbers afterwards (anchors unchanged).
enum CalibrationSheet {

    /// The type the four pixel readouts are set in. Kept as one constant because
    /// the column that holds them is sized from it — see `Form.Columns`.
    static let hintFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    /// The pixel readout for one anchor, e.g. `像素 (117, 432)`.
    static func hintText(_ p: PixelPoint) -> String {
        "像素 (\(Int(p.x.rounded())), \(Int(p.y.rounded())))"
    }

    /// How wide that readout comes out, so its column can be sized to it.
    ///
    /// Measured through a real label rather than the bare string. A field's cell
    /// keeps 4pt of the width for itself — `像素 (12345, 67890)` is 100.9pt of
    /// text but 104.9pt of label — so a column cut to the attributed string's
    /// width clips its last characters. That is the very failure this sizing
    /// exists to prevent, and measuring the string alone reintroduced it.
    static func hintTextWidth(_ p: PixelPoint) -> Double {
        let probe = NSTextField(labelWithString: hintText(p))
        probe.font = hintFont
        return Double(probe.cell!.cellSize(forBounds: NSRect(x: 0, y: 0,
                                                             width: 10_000,
                                                             height: 15)).width)
    }

    static func present(in window: NSWindow?,
                        anchors: CalibrationAnchors,
                        previous: CalibrationMap?,
                        editing: Bool = false,
                        completion: @escaping (CalibrationMap?) -> Void) {

        let alert = NSAlert()
        alert.messageText = editing ? "修改标定数值" : "设置坐标系"
        alert.informativeText = editing
            ? "改数值即可,四个标记的位置不变。坐标轴是对数刻度就勾选 log。"
            : "填入这四个标记对应的实际数值。坐标轴是对数刻度就勾选 log。"
        alert.alertStyle = .informational

        let form = Form(anchors: anchors, previous: previous)

        let trampoline = ClosureTarget { form.applyLogRepairs() }
        for box in [form.xLog, form.yLog] {
            box.target = trampoline
            box.action = #selector(ClosureTarget.fire(_:))
        }
        // NSControl holds its target weakly, so nothing else would keep the
        // trampoline alive past this function and the checkbox would go dead.
        objc_setAssociatedObject(alert, &logTrampolineKey, trampoline, .OBJC_ASSOCIATION_RETAIN)
        form.applyLogRepairs()

        alert.accessoryView = form.view
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { completion(nil); return }

            guard let xStart = number(form.xStart), let xEnd = number(form.xEnd),
                  let yStart = number(form.yStart), let yEnd = number(form.yEnd) else {
                complain(in: window, "有数值无法解析。请只填数字,例如 0、1.5、-3.2e-4。")
                completion(nil); return
            }

            let xIsLog = form.xLog.state == .on
            let yIsLog = form.yLog.state == .on

            if let problem = validate(anchors: anchors,
                                      xStart: xStart, xEnd: xEnd,
                                      yStart: yStart, yEnd: yEnd,
                                      xIsLog: xIsLog, yIsLog: yIsLog) {
                complain(in: window, problem)
                completion(nil); return
            }

            completion(CalibrationMap(anchors: anchors,
                                      xStartValue: xStart, xEndValue: xEnd,
                                      yStartValue: yStart, yEndValue: yEnd,
                                      xIsLogarithmic: xIsLog, yIsLogarithmic: yIsLog))
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// The sheet's accessory view and the controls read back from it once the
    /// user answers.
    ///
    /// Split out of `present` so the geometry can be measured without running a
    /// modal panel. It needs measuring: this form lays out three columns per row
    /// — the value's name, the pixel the anchor was clicked at, and the value
    /// field — and two of them used to sit at fixed x positions that crossed.
    /// The hint's 150pt box began at x=130 and the field at x=190, so their
    /// frames overlapped by 90pt for every anchor; the hint's *text* reached
    /// into the field from three figures on, and the field, added later, was
    /// drawn over it. A 117-pixel coordinate — an ordinary image — was already
    /// enough to lose the last character of its readout. The hint is the only
    /// thing tying a typed number to a mark on the chart, so losing it silently
    /// is worse than losing the field would have been.
    final class Form {

        static let height: Double = 320

        /// The four rows, in layout order. Exposed so the column geometry can be
        /// asserted from outside without guessing which label is which.
        struct Row {
            let name: NSTextField
            let hint: NSTextField
            let field: NSTextField
        }

        let view: NSView
        let columns: Columns
        let xStart: NSTextField
        let xEnd: NSTextField
        let yStart: NSTextField
        let yEnd: NSTextField
        let xLog: NSButton
        let yLog: NSButton
        let note: NSTextField
        private(set) var rows: [Row] = []

        init(anchors: CalibrationAnchors, previous: CalibrationMap?) {
            let columns = Columns.fitting(anchors)
            let width = columns.width
            let container = NSView(frame: NSRect(x: 0, y: 0,
                                                 width: width, height: Self.height))
            self.columns = columns
            self.view = container

            /// Collected as we go and handed to `rows` at the end: a local
            /// function that touched `self` could not be called until every
            /// stored property was set, and the fields it produces *are* those
            /// properties.
            var collected: [Row] = []

            /// A row: the name, the pixel the anchor was clicked at, and the
            /// value field — so the number being typed can be checked against
            /// the mark on the chart without leaving the sheet.
            ///
            /// Three columns at fixed x, never a flowing layout: `NSAlert` sizes
            /// its accessory view from the frame it is handed, so the widths
            /// have to be decided before the alert exists.
            func row(_ label: String, pixel: PixelPoint, value: Double,
                     y: Double) -> Row {
                let name = NSTextField(labelWithString: label)
                name.font = .systemFont(ofSize: 12, weight: .medium)
                name.lineBreakMode = .byTruncatingTail
                name.frame = NSRect(x: columns.nameX, y: y + 3,
                                    width: columns.nameWidth, height: 17)
                container.addSubview(name)

                let hint = NSTextField(labelWithString: CalibrationSheet.hintText(pixel))
                hint.font = CalibrationSheet.hintFont
                hint.textColor = .secondaryLabelColor
                hint.lineBreakMode = .byTruncatingTail
                // The frame is sized from this very string, so truncation should
                // be unreachable; the tooltip is here so that if a coordinate
                // ever does outgrow its column, the number is still readable.
                hint.toolTip = hint.stringValue
                hint.frame = NSRect(x: columns.hintX, y: y + 3,
                                    width: columns.hintWidth, height: 15)
                container.addSubview(hint)

                let field = NSTextField(frame: NSRect(x: columns.fieldX, y: y,
                                                      width: columns.fieldWidth, height: 22))
                field.stringValue = CalibrationSheet.formatForEditing(value)
                field.alignment = .right
                container.addSubview(field)

                let made = Row(name: name, hint: hint, field: field)
                collected.append(made)
                return made
            }

            func header(_ text: String, y: Double, color: NSColor) {
                let label = NSTextField(labelWithString: text)
                label.font = .systemFont(ofSize: 12, weight: .bold)
                label.textColor = color
                label.frame = NSRect(x: Columns.margin, y: y,
                                     width: width - Columns.margin * 2, height: 18)
                container.addSubview(label)
            }

            func logBox(_ title: String, on: Bool, y: Double) -> NSButton {
                let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
                box.frame = NSRect(x: Columns.margin, y: y,
                                   width: width - Columns.margin * 2, height: 18)
                box.state = on ? .on : .off
                container.addSubview(box)
                return box
            }

            // --- X axis ---------------------------------------------------
            header("X 轴", y: 292, color: CanvasView.xAxisColor)
            let xStartRow = row("起始值", pixel: anchors.xStart,
                                value: previous?.x.valueMin ?? 0, y: 262)
            let xEndRow = row("末端值", pixel: anchors.xEnd,
                              value: previous?.x.valueMax ?? 10, y: 222)
            let xLogBox = logBox("X 轴为对数刻度 (log10)",
                                 on: previous?.x.isLogarithmic ?? false, y: 192)

            // --- Y axis ---------------------------------------------------
            header("Y 轴", y: 152, color: CanvasView.yAxisColor)
            let yStartRow = row("起始值", pixel: anchors.yStart,
                                value: previous?.y.valueMin ?? 0, y: 122)
            let yEndRow = row("末端值", pixel: anchors.yEnd,
                              value: previous?.y.valueMax ?? 10, y: 82)
            let yLogBox = logBox("Y 轴为对数刻度 (log10)",
                                 on: previous?.y.isLogarithmic ?? false, y: 52)

            // What ticking a log box changed, if anything. A log axis has no zero
            // or negative value, so instead of failing on OK the sheet repairs
            // the number and says which one it touched. The clicked pixels are
            // never moved — only the figure the user would have had to work out.
            let noteField = NSTextField(labelWithString: "")
            noteField.font = .systemFont(ofSize: 10)
            noteField.textColor = .secondaryLabelColor
            noteField.lineBreakMode = .byWordWrapping
            noteField.maximumNumberOfLines = 2
            noteField.frame = NSRect(x: Columns.margin, y: 8,
                                     width: width - Columns.margin * 2, height: 28)
            container.addSubview(noteField)

            self.xStart = xStartRow.field
            self.xEnd = xEndRow.field
            self.yStart = yStartRow.field
            self.yEnd = yEndRow.field
            self.xLog = xLogBox
            self.yLog = yLogBox
            self.note = noteField
            self.rows = collected
        }

        /// Repairs any value a freshly ticked log box cannot describe, writes
        /// what it touched into the note, and returns that text.
        @discardableResult
        func applyLogRepairs() -> String {
            var repairs: [String] = []
            if xLog.state == .on { repairs += Self.repair(from: xStart, to: xEnd, axis: "X ") }
            if yLog.state == .on { repairs += Self.repair(from: yStart, to: yEnd, axis: "Y ") }
            let text = repairs.isEmpty
                ? ""
                : repairs.joined(separator: "、") + "(对数轴没有 0 和负数)"
            note.stringValue = text
            return text
        }

        private static func repair(from start: NSTextField, to end: NSTextField,
                                   axis: String) -> [String] {
            var done: [String] = []
            if let fixed = CalibrationSheet.logStartRepair(current: CalibrationSheet.number(start),
                                                          axisEnd: CalibrationSheet.number(end)) {
                start.stringValue = fixed
                done.append("\(axis)起点 → \(fixed)")
            }
            if let fixed = CalibrationSheet.logEndRepair(current: CalibrationSheet.number(end),
                                                        axisStart: CalibrationSheet.number(start)) {
                end.stringValue = fixed
                done.append("\(axis)末端 → \(fixed)")
            }
            return done
        }

        /// Where each column of a row starts and how wide it is.
        ///
        /// Derived from font metrics rather than written down, because the hint's
        /// width is not a constant: `像素 (0, 0)` measures 53.5pt and a
        /// five-figure coordinate 104.9pt, a 2× spread that no single fixed width
        /// covers. The columns are laid out left to right with explicit gaps, so
        /// overlap is impossible by construction rather than by a coincidence of
        /// numbers that only held for small images.
        struct Columns {
            let width: Double
            let nameWidth: Double
            let hintWidth: Double
            let fieldX: Double
            let fieldWidth: Double

            static let margin: Double = 16
            /// Gap between columns. Also the gutter the hint needs so it does
            /// not read as part of the name beside it.
            static let gap: Double = 8
            /// Enough for 起始值 / 末端值 (39.8pt measured) with room to spare.
            static let nameColumn: Double = 76
            /// Floor, so a one-figure coordinate does not pull the hint tight
            /// against the name and shift the field left of where it has always
            /// been.
            static let hintMinWidth: Double = 88
            /// What a value field is worth having. The sheet starts at
            /// `widthFloor` for ordinary anchors and only grows past it when a
            /// hint genuinely needs the room, so a calibration on a small image
            /// looks exactly as it did.
            static let fieldMinWidth: Double = 240
            static let widthFloor: Double = 460
            /// The most the sheet may ever become, whatever the coordinates.
            ///
            /// The bound is stated on the sheet rather than on the hint column,
            /// because the sheet is what could outgrow a screen: this panel is
            /// modal over a canvas and has no reason to be wide. At this width a
            /// coordinate can run to eleven figures before its readout is
            /// clipped, and the hint carries the full text as a tooltip from
            /// there on.
            static let maximumWidth: Double = 560
            /// A hair of slack on top of the measured cell width. The cell size
            /// is exact, but the column is then compared against it by a drawing
            /// path this code does not own, and being 2pt generous costs nothing.
            static let hintPadding: Double = 2

            var nameX: Double { Self.margin }
            var hintX: Double { Self.margin + Self.nameColumn + Self.gap }

            static func fitting(_ anchors: CalibrationAnchors) -> Columns {
                let widest = [anchors.xStart, anchors.xEnd, anchors.yStart, anchors.yEnd]
                    .map { CalibrationSheet.hintTextWidth($0) }
                    .max() ?? hintMinWidth
                // Whatever is left for the hint once the other columns and the
                // gaps are paid for — so the sheet cannot outgrow `maximumWidth`
                // however long a coordinate gets.
                let hintCeiling = maximumWidth - margin * 2 - nameColumn - gap * 2 - fieldMinWidth
                let hintWidth = min(hintCeiling, max(hintMinWidth, widest + hintPadding))
                let fieldX = margin + nameColumn + gap + hintWidth + gap
                let width = max(widthFloor, fieldX + fieldMinWidth + margin)
                return Columns(width: width,
                               nameWidth: nameColumn,
                               hintWidth: hintWidth,
                               fieldX: fieldX,
                               fieldWidth: width - fieldX - margin)
            }
        }
    }

    /// Everything that makes a set of calibration numbers unusable, as a message
    /// the user can act on, or nil when the numbers are fine. Split out from the
    /// sheet so the wording can be tested without driving a modal panel.
    static func validate(anchors: CalibrationAnchors,
                         xStart: Double, xEnd: Double,
                         yStart: Double, yEnd: Double,
                         xIsLog: Bool, yIsLog: Bool) -> String? {
        if xIsLog && (xStart <= 0 || xEnd <= 0) {
            return "X 轴勾了 log,但起始值和末端值都必须为正数(现在填的是 "
                + "\(formatForEditing(xStart)) 和 \(formatForEditing(xEnd)))。"
                + "对数轴没有 0 —— 把不是正数的那个改成正值,例如 1。"
        }
        if yIsLog && (yStart <= 0 || yEnd <= 0) {
            return "Y 轴勾了 log,但起始值和末端值都必须为正数(现在填的是 "
                + "\(formatForEditing(yStart)) 和 \(formatForEditing(yEnd)))。"
                + "对数轴没有 0 —— 把不是正数的那个改成正值,例如 1。"
        }
        if xStart == xEnd {
            return "X 轴的起始值和末端值不能相同(都是 \(formatForEditing(xStart)))"
                + ",否则无法确定比例。"
        }
        if yStart == yEnd {
            return "Y 轴的起始值和末端值不能相同(都是 \(formatForEditing(yStart)))"
                + ",否则无法确定比例。"
        }
        if abs(anchors.xEnd.x - anchors.xStart.x) < 1 {
            return "X 轴的两个标记几乎在同一列(相隔 "
                + "\(Int(abs(anchors.xEnd.x - anchors.xStart.x).rounded())) 像素)"
                + ",横向比例无法确定。请分别点在横轴的两端。"
        }
        if abs(anchors.yEnd.y - anchors.yStart.y) < 1 {
            return "Y 轴的两个标记几乎在同一行(相隔 "
                + "\(Int(abs(anchors.yEnd.y - anchors.yStart.y).rounded())) 像素)"
                + ",纵向比例无法确定。请分别点在纵轴的两端。"
        }
        return nil
    }

    private static func number(_ field: NSTextField) -> Double? {
        let raw = field.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !raw.isEmpty else { return nil }
        return Double(raw)
    }

    private static func formatForEditing(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%g", v)
    }

    /// A positive value for an axis start once that axis is marked logarithmic,
    /// or nil when what is already typed will do.
    static func logStartRepair(current: Double?, axisEnd: Double?) -> String? {
        guard let current, current <= 0 else { return nil }
        return formatForEditing(logStartDefault(below: axisEnd ?? 10))
    }

    /// A positive value for an axis end once that axis is logarithmic. Only a
    /// non-positive end needs repair — a log axis cannot show one.
    static func logEndRepair(current: Double?, axisStart: Double?) -> String? {
        guard let current, current <= 0 else { return nil }
        let base = (axisStart ?? 1) > 0 ? (axisStart ?? 1) : 1
        return formatForEditing(base * 10)
    }

    /// A positive default for a log axis' start. One is the value a person
    /// expects to type for a log axis, so it is used whenever the axis end
    /// leaves room for it; only an end at or below one steps down to the next
    /// lower power of ten, which keeps the start the minimum of the axis.
    static func logStartDefault(below end: Double) -> Double {
        if end > 1 { return 1 }
        guard end > 0 else { return 1 }
        let decade = pow(10.0, log10(end).rounded(.down))
        return decade < end ? decade : decade / 10
    }

    private static func complain(in window: NSWindow?, _ message: String) {
        let alert = NSAlert()
        alert.messageText = "标定数值有问题"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
