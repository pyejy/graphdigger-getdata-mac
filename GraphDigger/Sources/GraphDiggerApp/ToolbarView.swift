import AppKit
import GDCore

/// A button strip above the canvas.
///
/// The menu alone made the workflow opaque — nothing showed which tool was
/// active or what step came next, and the pipeline order (calibrate → pick
/// colour → digitise → export) was invisible. This bar shows the tools as
/// buttons with the active one highlighted and groups them in pipeline order.
///
/// The bar is buttons only: the status / zoom / summary text lives in a separate
/// strip that spans the window (`InfoBarView`). While it lived here it was
/// confined to the canvas column, so a wide window left most of it blank and the
/// text wrapped in a narrow one.
///
/// A label that never swallows mouse events.
///
/// NSTextField participates in hit testing even when it is a non-selectable
/// label, so any label overlapping a button silently blocks it. Labels here
/// must always pass clicks through.
private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ToolbarView: NSView {

    weak var delegate: ToolbarDelegate?

    /// Everything drawn in the bar's one row is centred on this line, measured
    /// from the top.
    private static let rowCenter: CGFloat = 26
    private static let buttonHeight: CGFloat = 28

    /// One tool that draws on the canvas, with the shortcut and tooltip it is
    /// advertised under.
    private struct ToolButton {
        let tool: ToolMode
        let title: String
        let symbol: String
        let shortcut: String
        var button: NSButton?
    }

    /// The row's specification.
    ///
    /// Static, and the single source both `build()` and `estimatedWidth` read,
    /// because the window's minimum width is derived from the estimate before any
    /// row exists — and a second hand-written copy of the table is exactly how
    /// the two drift apart.
    ///
    /// The first group sets things up, the second takes points, the third repairs
    /// them: a mis-digitised curve is fixed with decreasing effort — erase the
    /// bad points, or clear the stretch and re-take it. (The row's own undo/redo
    /// pair, at the far left, sits outside these three: it acts on whatever the
    /// last action was, not on the tool in hand.)
    ///
    /// Shortcuts stop at 9 because the menu bar uses ⌘0–⌘9.
    private static let toolSpecs: [ToolButton] = [
        ToolButton(tool: .browse, title: "浏览", symbol: "hand.raised", shortcut: "⌘0"),
        ToolButton(tool: .setScale, title: "标定", symbol: "ruler", shortcut: "⌘S"),
        ToolButton(tool: .pickLineColor, title: "取色", symbol: "eyedropper", shortcut: "⌘L"),
        ToolButton(tool: .gridDigitize, title: "区域取点", symbol: "rectangle.dashed", shortcut: "⌘D"),
        ToolButton(tool: .traceDigitize, title: "自动跟踪", symbol: "scribble", shortcut: "⌘T"),
        ToolButton(tool: .capture, title: "手工取点", symbol: "hand.point.up.left", shortcut: "⌘P"),
        ToolButton(tool: .eraser, title: "橡皮擦", symbol: "eraser", shortcut: "⌘E"),
        ToolButton(tool: .redigitize, title: "重新选点", symbol: "arrow.triangle.2.circlepath",
                   shortcut: "⌘R"),
    ]
    /// The same table with room for the button each spec grew at build time.
    private var toolButtons: [ToolButton] = toolSpecs

    /// Separators between `toolSpecs`, drawn *before* the button at each index.
    ///
    /// The gaps are small on purpose. The row and the data panel share the
    /// window, so every point spent on air here is a point the window minimum
    /// cannot afford on a 13-inch screen — see `MainLayout.narrowestScreenWidth`.
    /// Grouping that costs 12pt of whitespace is grouping the user pays for in
    /// a window too wide to fit.
    private static let groupBreaks: Set<Int> = [3, 6]
    /// What `build()` advances `x` by around a separator and around a button.
    ///
    /// Every one of these is at the bottom of what still reads as a gap. The row
    /// and the data panel share the window, so a point spent on air here is a
    /// point the window minimum cannot afford on a 13-inch screen — and the row
    /// is close enough to that limit that 撤销 had to be paid for out of these
    /// rather than added on top. What they were before is not worth restoring:
    /// the looser row bought nothing the buttons did not already say.
    private static let groupGapBefore: CGFloat = 6
    private static let groupGapAfter: CGFloat = 8
    private static let buttonGap: CGFloat = 3
    /// Before 复制数据, between 复制数据 and 导出…, and before 适配窗口.
    private static let outputGap: CGFloat = 8
    private static let copyGap: CGFloat = 3
    /// Between the 撤销/恢复 pair and the first tool button. Wider than
    /// `buttonGap` because neither segment is a tool — the two act on whatever
    /// the last action was, whichever tool took it — and the row has to say so
    /// without spending a separator rule, which costs 15pt of a row that has
    /// almost none to spend.
    private static let historyGap: CGFloat = 8
    /// Leading margin, and what `requiredWidth` adds past the last button.
    private static let leadingMargin: CGFloat = 6
    private static let trailingMargin: CGFloat = 6

    /// Height the 撤销/恢复 control is laid out at. The control's own natural
    /// height is a few points shorter; it is given the row's `buttonHeight` so
    /// that the cell is measured at the same height it is drawn at, which is
    /// what keeps `requiredWidth` and `build` agreeing on the same number.
    private static let historyControlHeight: CGFloat = 28

    /// `撤销 | 恢复`: one control, two segments — step back, step forward.
    ///
    /// **Icon only, and a segmented pair rather than two buttons — neither is a
    /// style choice.** The row has ~25pt of width to spare against the narrowest
    /// screen the app supports. 「撤销」 as a word measures 69pt where the symbol
    /// measures 39, and the symbol is the one every Mac user already reads as
    /// undo. Two separate icon buttons measure 39 + 39 + a gap — 81pt, which the
    /// row cannot afford — while the same two symbols joined in one segmented
    /// control measure 49. 撤销 and 恢复 are one idea (step back, step forward),
    /// and the control that draws them as one is also the one that fits. The
    /// names are carried by the segments' tooltips and by the Edit menu, which
    /// spells out 「撤销 擦除」 with the action it will take back.
    private var historyControl: NSSegmentedControl!

    private var exportButton: NSButton!
    private var copyButton: NSButton!
    private var fitButton: NSButton!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    override var isFlipped: Bool { true }

    // MARK: - Construction

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        var x: CGFloat = Self.leadingMargin

        // 撤销/恢复 leads the row: they are the one pair here that is not about
        // which tool is in hand, and the left edge is where every other Mac app
        // puts them.
        historyControl = Self.makeHistoryControl()
        historyControl.target = self
        historyControl.action = #selector(historyClicked(_:))
        historyControl.setToolTip("撤销上一步操作  (⌘Z)", forSegment: 0)
        historyControl.setToolTip("重做(恢复)被撤销的操作  (⇧⌘Z)", forSegment: 1)
        historyControl.frame = NSRect(x: x,
                                      y: Self.rowCenter - Self.historyControlHeight / 2,
                                      width: width(of: historyControl),
                                      height: Self.historyControlHeight)
        addSubview(historyControl)
        x += historyControl.frame.width + Self.historyGap

        // Tool buttons. The undo tools (橡皮擦 / 重新选点) are set apart from the
        // ones that take points, so the alternatives — 区域取点 / 自动跟踪 /
        // 手工取点 — read as a group rather than as consecutive steps.
        for index in toolButtons.indices {
            if Self.groupBreaks.contains(index) {
                x += Self.groupGapBefore
                let gap = NSBox(frame: NSRect(x: x, y: Self.rowCenter - 8, width: 1, height: 16))
                gap.boxType = .separator
                addSubview(gap)
                x += Self.groupGapAfter
            }
            let spec = toolButtons[index]
            let button = makeButton(title: spec.title,
                                    symbol: spec.symbol,
                                    action: #selector(toolButtonClicked(_:)))
            button.tag = index
            button.toolTip = "\(spec.title)  (\(spec.shortcut))"
            button.frame = NSRect(x: x, y: Self.rowCenter - Self.buttonHeight / 2,
                                  width: width(of: button), height: Self.buttonHeight)
            addSubview(button)
            toolButtons[index].button = button
            x += button.frame.width + Self.buttonGap
        }

        // Separator before the output actions.
        x += Self.groupGapBefore
        let separator = NSBox(frame: NSRect(x: x, y: Self.rowCenter - 12, width: 1, height: 24))
        separator.boxType = .separator
        addSubview(separator)
        x += Self.groupGapAfter

        copyButton = makeButton(title: Self.copyTitle, symbol: Self.copySymbol,
                                action: #selector(copyClicked(_:)))
        copyButton.toolTip = "把数据点复制到剪贴板(制表符分隔,可直接粘进 Excel)  (⌘C)"
        copyButton.frame = NSRect(x: x, y: Self.rowCenter - Self.buttonHeight / 2,
                                  width: width(of: copyButton), height: Self.buttonHeight)
        addSubview(copyButton)
        x += copyButton.frame.width + Self.copyGap

        exportButton = makeButton(title: Self.exportTitle, symbol: Self.exportSymbol,
                                  action: #selector(exportClicked(_:)))
        exportButton.toolTip = "导出为 CSV / TSV / TXT / XML / DXF / EPS"
        exportButton.frame = NSRect(x: x, y: Self.rowCenter - Self.buttonHeight / 2,
                                    width: width(of: exportButton), height: Self.buttonHeight)
        addSubview(exportButton)
        x += exportButton.frame.width + Self.outputGap

        fitButton = makeButton(title: Self.fitTitle, symbol: Self.fitSymbol,
                               action: #selector(fitClicked(_:)))
        fitButton.toolTip = "缩放到适合窗口  (⌘9)"
        fitButton.frame = NSRect(x: x, y: Self.rowCenter - Self.buttonHeight / 2,
                                 width: width(of: fitButton), height: Self.buttonHeight)
        addSubview(fitButton)
    }

    private func makeButton(title: String, symbol: String, action: Selector) -> NSButton {
        let button = Self.configuredButton(title: title, symbol: symbol)
        button.target = self
        button.action = action
        return button
    }

    /// A button carrying `title`, measured and configured exactly as the real row
    /// does.
    ///
    /// One place rather than one per call site, because the width the window
    /// reserves and the width it draws have to be the same number: the estimate
    /// that sizes the window minimum is a re-derivation of what `build` does, and
    /// the two only agree because they ask the same cell.
    ///
    /// The leading space separates the symbol from the word, and is skipped on
    /// the icon-only buttons — there it would be 4pt spent on nothing, in a row
    /// that counts every point.
    private static func configuredButton(title: String, symbol: String) -> NSButton {
        let button = NSButton(title: title.isEmpty ? "" : " \(title)", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        if #available(macOS 11.0, *) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        button.font = .systemFont(ofSize: 12)
        return button
    }

    /// How wide a control has to be for its own contents.
    ///
    /// Asked of the cell rather than estimated: the bezel's own margins and the
    /// symbol's width are not derivable from the title, and the estimate this
    /// used to do under-sized every button — 标定坐标系 was given 97pt for
    /// contents that need 106, so the label was clipped. Takes any `NSControl`,
    /// because the 撤销/恢复 control is a segmented control and its two segments
    /// are measured by the same rule as a button's title and symbol.
    private func width(of control: NSControl) -> CGFloat {
        let needed = control.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000,
                                                              height: Self.buttonHeight)).width
        // One point of slack: cellSize rounds to whole points and the button
        // draws its title centred, so a fractional shortfall can still shave a
        // pixel off a glyph.
        return ceil(needed) + 1
    }

    /// Width a button with these contents claims. Used by `requiredWidth`, by
    /// `estimatedWidth` and by the selftest, so the width the window reserves and
    /// the width it draws cannot drift apart. See `configuredButton`; the
    /// 撤销/恢复 pair is measured by `historyControlWidth` instead, because it is
    /// one segmented control rather than two buttons.
    static func measuredWidth(of title: String, symbol: String) -> CGFloat {
        let button = configuredButton(title: title, symbol: symbol)
        let needed = button.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000,
                                                             height: buttonHeight)).width
        return ceil(needed) + 1
    }

    /// The 撤销/恢复 pair's contents, as `build` names them.
    static let undoSymbol = "arrow.uturn.backward"
    static let redoSymbol = "arrow.uturn.forward"

    /// Builds the 撤销/恢复 control, configured exactly as the real row's is.
    ///
    /// One place rather than one per call site, because `estimatedWidth` — which
    /// sizes the window minimum before any row exists — has to read the same two
    /// symbols the row will draw. Two segments, momentary: each fires the action
    /// on its own click and neither stays selected, which is what a push button
    /// does and what a *pair of buttons* would have done had the row been able
    /// to afford two of them.
    static func makeHistoryControl() -> NSSegmentedControl {
        var images: [NSImage] = []
        for symbol in [undoSymbol, redoSymbol] {
            if #available(macOS 11.0, *),
               let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                images.append(image)
            } else {
                images.append(NSImage())
            }
        }
        let control = NSSegmentedControl(images: images, trackingMode: .momentary,
                                         target: nil, action: nil)
        control.segmentStyle = .rounded
        control.font = .systemFont(ofSize: 12)
        return control
    }

    /// Width the 撤销/恢复 control claims, measured the way `build` measures it.
    /// Read by `estimatedWidth`; the selftest reads it to keep the two in step.
    static var historyControlWidth: CGFloat {
        let control = makeHistoryControl()
        let needed = control.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000,
                                                              height: historyControlHeight)).width
        return ceil(needed) + 1
    }

    /// The output group's three buttons, spelled once for `build`, for
    /// `estimatedWidth` and for the selftest.
    ///
    /// Two of the three were shortened when 撤销 arrived, and they stay short now
    /// that 恢复 has joined it. The two together are what the pair of segments
    /// costs the row, so the space had to come from somewhere. It came from here
    /// rather than from the tool buttons, because these three are *actions* on
    /// the work — their tooltips already carry the full sentence, and 「复制」
    /// and 「适配」 beside their symbols lose nothing a Mac user was relying on.
    /// 导出… keeps its ellipsis: it is the one of the three that opens a dialog.
    static let copyTitle = "复制"
    static let copySymbol = "doc.on.clipboard"
    static let exportTitle = "导出…"
    static let exportSymbol = "square.and.arrow.up"
    static let fitTitle = "适配"
    static let fitSymbol = "arrow.up.left.and.arrow.down.right"

    /// Width the button row needs. The window sets its minimum from this so the
    /// right-hand buttons cannot be clipped.
    ///
    /// Deferred to the last laid-out button when the row exists: `estimatedWidth`
    /// is a re-derivation of what `build` already did, and when the two disagree
    /// the row is laid out at a width that cuts off its last button — which is
    /// what the user saw. Measuring the row is the same fact with no second copy
    /// of it. The estimate reads the same constants `build` does, so it cannot
    /// drift the same way even when it is the one consulted.
    var requiredWidth: CGFloat {
        if let last = lastButtonFrame { return last.maxX + Self.trailingMargin }
        return estimatedWidth
    }

    /// The frame of the rightmost button in the laid-out row, or nil before the
    /// row has one.
    private var lastButtonFrame: NSRect? {
        let frames = subviews.compactMap { $0 as? NSButton }.map(\.frame)
        guard let rightmost = frames.max(by: { $0.maxX < $1.maxX }) else { return nil }
        return rightmost.maxX > 0 ? rightmost : nil
    }

    /// Width of the info bar's parameter control: the readout plus the slider.
    ///
    /// Fixed rather than measured because a slider has no contents of its own to
    /// measure — and because one that grew with the window would make the same
    /// drag mean a different size on a different screen. It is one width for all
    /// three parameters so the strip does not reflow when the tool changes: the
    /// control is the same object, showing a different number.
    static var parameterControlWidth: CGFloat {
        parameterLabelWidth + parameterLabelGap + parameterSliderWidth
    }
    /// Wide enough for the longest reading either range can produce. `半径 120`
    /// is the widest at about 45pt and `间距 40px` at about 51pt, so the field is
    /// sized to the latter with room for the cell's own margins — clipped, the
    /// number that justifies the whole control reads as 「半径 1」 and the user
    /// cannot tell 120 from 12.
    static let parameterLabelWidth: CGFloat = 58
    static let parameterLabelGap: CGFloat = 6
    static let parameterSliderWidth: CGFloat = 126
    /// Height of the info bar's controls. Shorter than the toolbar's: the strip
    /// is two text rows tall, and a 28pt control would sit on the second one.
    static let infoBarControlHeight: CGFloat = 22

    /// The row's width by arithmetic, for the case where no row has been built
    /// yet — which is the case when `AppDelegate` sizes the window, since the
    /// minimum has to be known before the window exists.
    ///
    /// Every gap and margin comes from the same constant `build` uses; a check
    /// that this agrees with a real row is what stops the two drifting, since
    /// nothing here can be measured.
    private var estimatedWidth: CGFloat {
        var total = Self.leadingMargin
        total += Self.historyControlWidth + Self.historyGap
        for (index, spec) in Self.toolSpecs.enumerated() {
            if Self.groupBreaks.contains(index) { total += Self.groupGapBefore + Self.groupGapAfter }
            total += Self.measuredWidth(of: spec.title, symbol: spec.symbol) + Self.buttonGap
        }
        total += Self.groupGapBefore + Self.groupGapAfter          // separator, 复制
        total += Self.measuredWidth(of: Self.copyTitle, symbol: Self.copySymbol) + Self.copyGap
        total += Self.measuredWidth(of: Self.exportTitle, symbol: Self.exportSymbol) + Self.outputGap
        total += Self.measuredWidth(of: Self.fitTitle, symbol: Self.fitSymbol)
        return total + Self.trailingMargin
    }

    // MARK: - State

    func setActiveTool(_ tool: ToolMode) {
        for spec in toolButtons {
            guard let button = spec.button else { continue }
            let isActive = spec.tool == tool
            button.state = isActive ? .on : .off
            button.contentTintColor = isActive ? .controlAccentColor : nil
            button.bezelColor = isActive ? .controlAccentColor : nil
        }
    }

    /// Gates the tools that need something to act on, the output actions, and
    /// the two halves of the history control. The status text itself belongs to
    /// the info bar below.
    func update(isLoadingEnabled: Bool, canExport: Bool, canUndo: Bool, canRedo: Bool) {
        copyButton.isEnabled = canExport
        exportButton.isEnabled = canExport
        // Each half greyed out at the bottom of its own stack rather than hidden:
        // a segment that came and went with the history would move every other
        // button in the row, and the user would lose the one thing this control
        // is for — a fixed place to reach for after a mistake. The two are gated
        // apart because they run out at different times: after one 撤销 there is
        // something to 恢复 and possibly nothing left to 撤销, and a 恢复 the user
        // cannot see is one they will not remember they have.
        historyControl.setEnabled(canUndo, forSegment: 0)
        historyControl.setEnabled(canRedo, forSegment: 1)
        // Tools other than browse need an image to act on.
        for spec in toolButtons where spec.tool != .browse {
            spec.button?.isEnabled = isLoadingEnabled
        }
    }

    // MARK: - Actions

    @objc private func historyClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: delegate?.toolbarDidRequestUndo(self)
        case 1: delegate?.toolbarDidRequestRedo(self)
        default: break
        }
    }

    @objc private func toolButtonClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < toolButtons.count else { return }
        delegate?.toolbar(self, didSelect: toolButtons[sender.tag].tool)
    }

    @objc private func copyClicked(_ sender: Any?) { delegate?.toolbarDidRequestCopy(self) }
    @objc private func exportClicked(_ sender: Any?) { delegate?.toolbarDidRequestExport(self, from: exportButton) }
    @objc private func fitClicked(_ sender: Any?) { delegate?.toolbarDidRequestFit(self) }
}

/// The full-width strip between the toolbar and the canvas.
///
/// It carries the current step, the status line, the active tool's own parameter
/// and the extracted-data summary, the way a browser's address/status strip does.
/// It spans the whole window rather than the canvas column: that is what makes
/// the grey field above the chart and the panel below read as one application
/// frame.
///
/// The parameter control lives here rather than in the button row because the
/// row and the panel share the window: adding it there put the window minimum
/// past what a 13-inch screen can show. This strip has height to spare and the
/// control belongs to a tool, not to the workflow the row advertises.
///
/// It is shown only while the tool in hand has a parameter, and it shows that
/// tool's parameter. The control began as the eraser's circle alone, and the two
/// sampling spacings were elsewhere — 网格间距 behind a modal dialog in the 操作
/// menu the user never found, the trace density nowhere at all. A number that
/// decides how many points a curve gets is part of the tool, and a tool whose
/// setting cannot be seen is one that cannot be aimed. Keeping the readout bound
/// to the tool also keeps it honest: a permanently visible 半径 18 reads as
/// though the eraser were quietly armed while 手工取点 is doing the work.
final class InfoBarView: NSView {

    weak var delegate: InfoBarDelegate?

    private var stepLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var lineLabel: NSTextField!
    private var parameterLabel: PassthroughLabel!
    private var parameterSlider: NSSlider!
    /// Which parameter the right end is showing, or nil while the tool in hand
    /// has none. Starts nil and is set by the window on the first refresh, so a
    /// bar that never hears from its owner does not open showing a control that
    /// may belong to no tool at all.
    private var parameter: ToolParameter?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    override var isFlipped: Bool { true }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stepLabel = PassthroughLabel(labelWithString: "")
        stepLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stepLabel.textColor = .labelColor
        addSubview(stepLabel)

        statusLabel = PassthroughLabel(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        addSubview(statusLabel)

        lineLabel = PassthroughLabel(labelWithString: "")
        lineLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        lineLabel.textColor = .secondaryLabelColor
        lineLabel.alignment = .right
        addSubview(lineLabel)

        buildParameterControl()
        addRule()
        layoutTextRows()
    }

    /// `半径 18  [———●———]`, `间距 8px  [●——————]`: the number the tool in hand
    /// works by, and a knob to move it.
    ///
    /// One slider for all three rather than one per parameter: they are the same
    /// gesture on the same kind of number, and three overlapping controls that
    /// take turns being visible is three chances for two of them to be on screen
    /// at once. `setParameter` re-ranges the one slider and rewrites its readout.
    ///
    /// A slider rather than the `− ⌀NN +` stepper this began as. The useful range
    /// is twenty presses end to end — and for the spacings it is forty — and both
    /// kinds of number are judged by watching the canvas, so the control has to be
    /// draggable while the eye is on the result. The stepper made that a chore and
    /// left two buttons that stopped answering at the ends of the range, which is
    /// indistinguishable from two broken buttons.
    ///
    /// The ring's readout is the radius, which is what the canvas stores and what
    /// the hit test converts. It used to be written `⌀`, which was out by a factor
    /// of two: the circle drawn at the default is 36pt across, not 18.
    private func buildParameterControl() {
        parameterSlider = NSSlider(value: Double(CanvasView.eraserDefaultRadius),
                                   minValue: Double(CanvasView.eraserMinRadius),
                                   maxValue: Double(CanvasView.eraserMaxRadius),
                                   target: self,
                                   action: #selector(parameterSliderMoved(_:)))
        // Continuous: the whole point is that the canvas changes while the knob is
        // moving — the circle resizing, or the next 区域取点 扫描线 spacing. On
        // mouse-up only, the user would be aiming at a value they cannot see until
        // they let go.
        parameterSlider.isContinuous = true
        parameterSlider.controlSize = .small
        parameterSlider.isHidden = true
        addSubview(parameterSlider)

        parameterLabel = PassthroughLabel(labelWithString: "")
        parameterLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        parameterLabel.textColor = .labelColor
        parameterLabel.alignment = .right
        parameterLabel.isHidden = true
        addSubview(parameterLabel)
    }

    /// A hairline along the bottom edge, so the strip reads as chrome above the
    /// canvas rather than as part of it.
    private func addRule() {
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor.separatorColor.cgColor
        rule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        rule.autoresizingMask = [.width, .minYMargin]
        addSubview(rule)
    }

    /// Width reserved on the right of the first row for the data summary.
    private static let summaryWidth: CGFloat = 220
    private static let margin: CGFloat = 12
    /// Gap between the status text and the ring control.
    private static let controlGap: CGFloat = 12
    /// Centre line of the second row, where the status text and the ring control
    /// both sit.
    private static let secondRowCenter: CGFloat = 37

    private func layoutTextRows() {
        let width = bounds.width
        stepLabel.frame = NSRect(x: Self.margin, y: 5,
                                 width: max(0, width - Self.summaryWidth - Self.margin * 2),
                                 height: 17)
        lineLabel.frame = NSRect(x: max(Self.margin, width - Self.summaryWidth - Self.margin), y: 5,
                                 width: Self.summaryWidth, height: 17)

        // The parameter control takes its width from the right edge, and the
        // status text is given whatever is left — the reverse would slide the
        // control sideways as the status line grew. While it is hidden it takes no
        // width at all, and the status line gets the whole row back.
        let controlWidth = parameter == nil ? 0 : ToolbarView.parameterControlWidth
        let controlX = max(Self.margin, width - Self.margin - controlWidth)
        let controlHeight = ToolbarView.infoBarControlHeight
        let rowY = Self.secondRowCenter - controlHeight / 2

        parameterLabel.frame = NSRect(x: controlX, y: Self.secondRowCenter - 8,
                                      width: ToolbarView.parameterLabelWidth, height: 16)
        parameterSlider.frame = NSRect(x: controlX + ToolbarView.parameterLabelWidth
                                         + ToolbarView.parameterLabelGap,
                                       y: rowY, width: ToolbarView.parameterSliderWidth,
                                       height: controlHeight)

        // The separating gap is only worth reserving when there is something to
        // be separated from.
        let statusGap = parameter == nil ? 0 : Self.controlGap
        statusLabel.frame = NSRect(x: Self.margin, y: Self.secondRowCenter - 8,
                                   width: max(0, controlX - Self.margin - statusGap),
                                   height: 16)
    }

    override func layout() {
        super.layout()
        layoutTextRows()
    }

    func update(step: String, status: String, lineSummary: String) {
        stepLabel.stringValue = step
        statusLabel.stringValue = status
        lineLabel.stringValue = lineSummary
    }

    /// Points the right end at a parameter and gives it a value, or clears it.
    ///
    /// Both halves in one call rather than a setter plus an update: a parameter
    /// whose knob still holds the previous parameter's value reads as a setting
    /// that is *wrong*, not as one that has not arrived yet, and the two calls
    /// would be a window in which exactly that is on screen.
    ///
    /// Called from every `refreshUI`, so a re-target at the parameter already
    /// showing has to be cheap and, above all, must not reassign the slider's
    /// range: that snaps the knob to the new scale and would fight a drag in
    /// progress. Only a real switch does the re-ranging.
    func setParameter(_ parameter: ToolParameter?, value: Double) {
        guard parameter != self.parameter else {
            if parameter != nil { updateParameter(value: value) }
            return
        }
        self.parameter = parameter
        guard let parameter else {
            parameterSlider.isHidden = true
            parameterLabel.isHidden = true
            needsLayout = true
            return
        }
        let range = parameter.range
        parameterSlider.minValue = range.lowerBound
        parameterSlider.maxValue = range.upperBound
        parameterSlider.toolTip = parameter.toolTip
        parameterLabel.toolTip = parameter.toolTip
        // Set before unhiding: the knob has to be on the new scale by the time it
        // is on screen, or the first frame shows it wherever the old range left it.
        parameterSlider.doubleValue = value.rounded()
        parameterLabel.stringValue = parameter.readout(value)
        parameterSlider.isHidden = false
        parameterLabel.isHidden = false
        needsLayout = true
    }

    /// Reports a parameter's value. The canvas owns the number — it is the one
    /// that clamps it — and this writes it into the readout and the knob.
    ///
    /// Whole numbers only: these are sizes the user is choosing, not measurements,
    /// and a readout of `间距 7.999999` would be both unreadable and a lie about
    /// the precision on offer.
    func updateParameter(value: Double) {
        guard let parameter else { return }
        let whole = value.rounded()
        // Not an unconditional assignment: this runs from the slider's own action
        // while the knob is under the pointer, and writing the value back mid-drag
        // would fight the gesture.
        if abs(parameterSlider.doubleValue - whole) > 0.001 { parameterSlider.doubleValue = whole }
        parameterLabel.stringValue = parameter.readout(whole)
    }

    @objc private func parameterSliderMoved(_ sender: NSSlider) {
        guard let parameter else { return }
        delegate?.infoBar(self, didSetParameter: parameter, to: sender.doubleValue)
    }
}

/// The info bar's own callbacks. Separate from `ToolbarDelegate` because the
/// two strips are separate views and the app wires them separately.
protocol InfoBarDelegate: AnyObject {
    /// A parameter now stands at `value`, in that parameter's own unit, as the
    /// slider shows it. Absolute rather than a delta: a slider reports a position,
    /// and converting it to a step would make the value depend on where the drag
    /// started. Which parameter it is is carried along because one slider serves
    /// all of them, and only the receiver knows what each number means.
    func infoBar(_ infoBar: InfoBarView, didSetParameter parameter: ToolParameter, to value: Double)
}

protocol ToolbarDelegate: AnyObject {
    func toolbar(_ toolbar: ToolbarView, didSelect tool: ToolMode)
    func toolbarDidRequestUndo(_ toolbar: ToolbarView)
    func toolbarDidRequestRedo(_ toolbar: ToolbarView)
    func toolbarDidRequestCopy(_ toolbar: ToolbarView)
    func toolbarDidRequestExport(_ toolbar: ToolbarView, from sender: NSView)
    func toolbarDidRequestFit(_ toolbar: ToolbarView)
}
