import AppKit
import GDCore

/// Asked by the sidebar for anything that changes the project.
protocol SidebarViewDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarView, didSelectLine id: UUID)
    func sidebar(_ sidebar: SidebarView, didSetOrder order: PointOrder, for id: UUID)
    func sidebar(_ sidebar: SidebarView, didSetVisible visible: Bool, for id: UUID)
    func sidebar(_ sidebar: SidebarView, didRenameLine id: UUID, to name: String)
    func sidebarDidRequestAddLine(_ sidebar: SidebarView)
    func sidebar(_ sidebar: SidebarView, didRequestRemoveLine id: UUID)

    /// A number typed into the point table — FR-7.2.
    ///
    /// Returns whether it was taken. The panel puts the previous number back when
    /// it was not, because a cell that goes on showing a value the model refused
    /// is worse than the edit failing: the user reads it as saved.
    ///
    /// `row` is a position in the table, which is the **displayed** order. Turning
    /// that into a stored index is the canvas' job —
    /// `CanvasView.setCoordinate(_:of:atDisplayIndex:)` — and deliberately not the
    /// panel's, which does not know that the two differ.
    func sidebar(_ sidebar: SidebarView, didEditPointAt row: Int,
                 axis: PointCoordinate, to value: Double) -> Bool

    /// The ⌫ key in the point table.
    func sidebar(_ sidebar: SidebarView, didRequestRemovePointAt row: Int)
}

/// The data table, with one extra key: ⌫ deletes the selected row's point.
///
/// Caught in the table rather than in a menu because that is where the focus is
/// once the user has started working in the list — and a menu shortcut cannot
/// reach it, because a table's field editor takes the keystroke first. While a
/// cell *is* being edited the field editor wins, which is what makes ⌫ mean "one
/// character" inside a number and "this point" outside one.
private final class PointTableView: NSTableView {
    var onDeleteRow: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), selectedRow >= 0 {
            onDeleteRow?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }
}

private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The right-hand panel: the curve list above, the live point table below.
///
/// The point table is the reason this exists. Digitising without seeing the
/// numbers is working blind — a mis-picked colour or a calibration slip is
/// obvious here the moment a value appears, and the table scrolls so a traced
/// curve of several thousand points stays usable.
///
/// Several curves are listed at once and each carries its own colour and point
/// count. Selecting one makes it the target of the next digitising action, which
/// is what multi-curve extraction means in practice: pick the red curve, extract
/// it, select the blue curve, extract that.
final class SidebarView: NSView {

    weak var delegate: SidebarViewDelegate?

    private var lines: [CurveLine] = []
    private var calibration: CalibrationMap?
    /// Which mapping each curve is measured in — FR-13. Nil means "every curve
    /// shares `calibration`", which is what every caller before multi-system
    /// projects said, honestly.
    private var calibrationFor: CalibrationResolver?
    private var activeID: UUID?

    /// The mapping for one curve. A resolver, once supplied, is authoritative —
    /// same rule as `Exporter.map(for:resolver:)`: a curve whose own system has
    /// no mapping gets nil, not the active system's numbers, because those would
    /// be a neighbouring panel's units wearing this curve's points.
    private func calibration(for line: CurveLine) -> CalibrationMap? {
        guard let calibrationFor else { return calibration }
        return calibrationFor(line)
    }

    /// Set while `update` reasserts the selected row. Selecting a row posts a
    /// selection-changed notification, which the delegate answers by selecting
    /// the line, which refreshes the panel, which selects the row again — an
    /// unbounded loop that crashed the app the moment a second curve existed.
    private var isSyncingSelection = false

    private let curveTable = NSTableView()
    private let pointTable = PointTableView()
    private var orderPopUp: NSPopUpButton!
    private var orderHint: PassthroughLabel!
    private var emptyLabel: PassthroughLabel!
    private var curveHeading: NSTextField!
    private var curveScroll: NSScrollView!
    private var curveEmptyLabel: PassthroughLabel!
    private var addButton: NSButton!
    private var removeButton: NSButton!
    private var orderHeading: NSTextField!
    private var pointHeading: NSTextField!
    private var pointScroll: NSScrollView!
    private var curveBox: CardView!
    private var pointBox: CardView!
    private var orderBox: CardView!
    private var curveButtonRow: NSView!

    /// The 1pt rule down the panel's left edge, dividing it from the canvas.
    private var edgeRule: NSView!

    private static let pointColumns = ["index", "x", "y"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    override var isFlipped: Bool { true }

    /// The grey field the cards sit on.
    static let panelColor = NSColor(calibratedWhite: 0.937, alpha: 1)
    /// Tint of a card's title band, a step darker than the panel.
    static let headerFill = NSColor(calibratedWhite: 0.886, alpha: 1)
    /// The Excel grid: three steps darker than a card body, which is what made
    /// the rules read as structure instead of floating on white.
    static let gridColor = NSColor(calibratedWhite: 0.82, alpha: 1)
    /// A card's outline. Not `separatorColor`: that is a mid grey tuned for
    /// hairlines on white, and against this panel it measured within a point of
    /// the panel itself, so the cards had no edge at all. The whole point of the
    /// field is that the white cards sit *on* something.
    static let cardBorder = NSColor(calibratedWhite: 0.78, alpha: 1)

    // MARK: - Construction

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = Self.panelColor.cgColor

        // A rule down the left edge: without it the panel and the canvas below it
        // were both window background and the boundary was invisible.
        edgeRule = NSView()
        edgeRule.wantsLayer = true
        edgeRule.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(edgeRule)

        // ---- 曲线 card ----------------------------------------------------
        curveHeading = heading("曲线")
        curveHeading.alignment = .left

        curveTable.headerView = nil
        curveTable.rowHeight = 24
        curveTable.selectionHighlightStyle = .regular
        curveTable.backgroundColor = .textBackgroundColor
        curveTable.gridStyleMask = [.solidHorizontalGridLineMask]
        curveTable.gridColor = Self.gridColor
        curveTable.dataSource = self
        curveTable.delegate = self
        let curveColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("curve"))
        curveColumn.resizingMask = .autoresizingMask
        curveTable.addTableColumn(curveColumn)
        let curveScroll = scroll(around: curveTable)

        curveEmptyLabel = PassthroughLabel(labelWithString: "还没有曲线。\n点下面的「新增曲线」,\n再用「取色」在图上取色。")
        curveEmptyLabel.font = .systemFont(ofSize: 11)
        curveEmptyLabel.textColor = .tertiaryLabelColor
        curveEmptyLabel.lineBreakMode = .byWordWrapping
        curveEmptyLabel.maximumNumberOfLines = 3
        curveEmptyLabel.alignment = .center
        curveScroll.isHidden = true
        curveEmptyLabel.isHidden = false

        let curveBox = card(header: curveHeading,
                            body: [curveScroll, curveEmptyLabel], width: Self.pad * 2)
        let addButton = NSButton(title: "新增曲线", target: self, action: #selector(addLineClicked(_:)))
        addButton.bezelStyle = .rounded
        addButton.font = .systemFont(ofSize: 11)
        let removeButton = NSButton(title: "删除曲线", target: self, action: #selector(removeLineClicked(_:)))
        removeButton.bezelStyle = .rounded
        removeButton.font = .systemFont(ofSize: 11)
        let buttons = NSView()
        buttons.addSubview(addButton)
        buttons.addSubview(removeButton)
        curveBox.addSubview(buttons)
        self.curveButtonRow = buttons

        // ---- 取点顺序 card ------------------------------------------------
        orderHeading = heading("取点顺序")
        orderPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        orderPopUp.font = .systemFont(ofSize: 11)
        for order in PointOrder.allCases {
            orderPopUp.addItem(withTitle: order.displayName)
            orderPopUp.lastItem?.representedObject = order.rawValue
        }
        orderPopUp.target = self
        orderPopUp.action = #selector(orderChanged(_:))
        orderPopUp.toolTip = "点与点的先后决定连线走向。若曲线不是从左到右取的,改这里即可。"

        orderHint = PassthroughLabel(labelWithString: "")
        orderHint.font = .systemFont(ofSize: 10)
        orderHint.textColor = .secondaryLabelColor
        orderHint.lineBreakMode = .byWordWrapping
        orderHint.maximumNumberOfLines = 3

        let orderBox = card(header: orderHeading, body: [orderPopUp, orderHint],
                            width: Self.pad * 2)
        // Keep the subviews reachable: the card's own layout positions them, so
        // it has to know which ones are the pop-up and the hint.
        orderBox.body = [orderPopUp, orderHint]

        // ---- 数据点 card --------------------------------------------------
        pointHeading = heading("数据点")
        pointTable.headerView = NSTableHeaderView()
        pointTable.rowHeight = 20
        pointTable.usesAlternatingRowBackgroundColors = false
        pointTable.backgroundColor = .textBackgroundColor
        // Excel-style: a hairline between every row and column, so the numbers
        // read as a grid instead of floating on white.
        pointTable.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        pointTable.gridColor = Self.gridColor
        pointTable.intercellSpacing = NSSize(width: 0, height: 0)
        pointTable.dataSource = self
        pointTable.delegate = self
        pointTable.toolTip = "双击 X 或 Y 单元格可直接改数值;⌫ 删除选中的点"
        pointTable.onDeleteRow = { [weak self] row in
            guard let self else { return }
            self.delegate?.sidebar(self, didRequestRemovePointAt: row)
        }
        let titles = ["#", "X", "Y"]
        let widths: [CGFloat] = [36, 0, 0]
        for (index, identifier) in Self.pointColumns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = titles[index]
            if widths[index] > 0 { column.width = widths[index] }
            pointTable.addTableColumn(column)
        }
        let pointScroll = scroll(around: pointTable)

        emptyLabel = PassthroughLabel(labelWithString: "还没有数据点。\n\n选中一条曲线,用「区域取点」或\n「自动跟踪」取点后,这里会实时\n显示换算后的坐标值。")
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 6

        let pointBox = card(header: pointHeading, body: [pointScroll, emptyLabel],
                            width: Self.pad * 2)

        self.curveBox = curveBox
        self.pointBox = pointBox
        self.orderBox = orderBox
        // Locals shadow the properties of the same name, so these three have to
        // be stored explicitly or the panel's own references stay nil.
        self.curveScroll = curveScroll
        self.pointScroll = pointScroll
        self.addButton = addButton
        self.removeButton = removeButton
    }

    private static let pad: CGFloat = 8

    private func heading(_ text: String) -> NSTextField {
        let label = PassthroughLabel(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    /// A section: a titled header band over a bordered body, the two separated
    /// and the whole thing outlined with a hairline. This is the Excel-table
    /// reading the user asked for — an explicit box per section instead of
    /// rules that bleed off both edges and boxes that never close.
    ///
    /// Returns the section view; `body` subviews are added into it and given
    /// frames by `layout()`, which is where the heights are known.
    private func card(header: NSTextField, body: [NSView], width: CGFloat) -> CardView {
        let box = CardView()
        box.headerView = header
        box.body = body
        box.addSubview(header)
        for view in body { box.addSubview(view) }
        addSubview(box)
        return box
    }

    private func scroll(around table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        return scroll
    }

    override func layout() {
        super.layout()
        let pad = Self.pad
        let w = bounds.width
        let inner = max(40, w - pad * 2)

        edgeRule.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)

        var y: CGFloat = 10

        // ---- 曲线 ---------------------------------------------------------
        // A fixed band: tall enough for a handful of curves, short enough that
        // the data table below keeps the rest of the panel. Sizing it from the
        // panel height is what left the dead space the user objected to.
        let curveBody: CGFloat = 104
        curveBox.frame = NSRect(x: pad, y: y, width: inner,
                                height: CardView.headerHeight + curveBody)
        let curveInner = curveBox.contentFrame
        curveScroll.frame = NSRect(x: curveInner.minX, y: curveInner.minY,
                                   width: curveInner.width, height: curveBody - 34)
        curveEmptyLabel.frame = NSRect(x: curveInner.minX + 4, y: curveInner.minY + 8,
                                       width: curveInner.width - 8, height: 60)
        curveButtonRow.frame = NSRect(x: curveInner.minX,
                                      y: curveInner.minY + curveBody - 30,
                                      width: curveInner.width, height: 22)
        let halfWidth = (curveInner.width - 8) / 2
        addButton.frame = NSRect(x: 0, y: 0, width: halfWidth, height: 22)
        removeButton.frame = NSRect(x: halfWidth + 8, y: 0, width: halfWidth, height: 22)
        y += curveBox.frame.height + Self.gap

        // ---- 取点顺序 -----------------------------------------------------
        let orderBody: CGFloat = 22 + 4 + 30
        orderBox.frame = NSRect(x: pad, y: y, width: inner,
                                height: CardView.headerHeight + orderBody)
        let orderInner = orderBox.contentFrame
        orderPopUp.frame = NSRect(x: orderInner.minX, y: orderInner.minY,
                                  width: orderInner.width, height: 22)
        orderHint.frame = NSRect(x: orderInner.minX, y: orderInner.minY + 26,
                                 width: orderInner.width, height: 30)
        y += orderBox.frame.height + Self.gap

        // ---- 数据点 -------------------------------------------------------
        // The table takes whatever is left. A short panel would crush it, so a
        // floor is applied and the window's own minimum height keeps the panel
        // above that in practice.
        let available = bounds.height - y - 10
        pointBox.frame = NSRect(x: pad, y: y, width: inner,
                                height: max(CardView.headerHeight + 120, available))
        let pointInner = pointBox.contentFrame
        pointScroll.frame = NSRect(x: pointInner.minX, y: pointInner.minY,
                                   width: pointInner.width, height: pointInner.height)
        emptyLabel.frame = NSRect(x: pointInner.minX + 4, y: pointInner.minY + 8,
                                  width: pointInner.width - 8, height: 100)

        sizeColumns()
    }

    /// Gap between one card and the next.
    private static let gap: CGFloat = 10

    /// Hands each table's columns the width actually available inside its scroll
    /// view. NSTableView does not derive column widths from its own bounds.
    private func sizeColumns() {
        let curveWidth = max(120, curveScroll.contentSize.width)
        curveTable.tableColumns.first?.width = curveWidth

        let pointWidth = max(120, pointScroll.contentSize.width)
        // Fixed # column, the rest split evenly between X and Y.
        let indexWidth: CGFloat = 40
        let valueWidth = max(50, floor((pointWidth - indexWidth - 4) / 2))
        for column in pointTable.tableColumns {
            switch column.identifier.rawValue {
            case "index": column.width = indexWidth
            default:      column.width = valueWidth
            }
        }
    }

    // MARK: - Update

    /// Rebuilds the panel from the project state. Cheap: the tables only build
    /// the rows that are on screen, so a curve of thousands of points costs the
    /// same as one of ten.
    func update(lines: [CurveLine], calibration: CalibrationMap?, activeID: UUID?,
                resolvingWith resolver: CalibrationResolver? = nil) {
        self.lines = lines
        self.calibration = calibration
        self.calibrationFor = resolver
        self.activeID = activeID

        curveTable.reloadData()
        curveScroll.isHidden = lines.isEmpty
        curveEmptyLabel.isHidden = !lines.isEmpty
        removeButton.isEnabled = activeID != nil
        let desiredRow = activeID.flatMap { id in
            lines.firstIndex(where: { $0.id == id })
        }
        let needsRowSync = desiredRow != nil
            ? curveTable.selectedRow != desiredRow
            : curveTable.selectedRow != -1
        if needsRowSync {
            isSyncingSelection = true
            if let desiredRow {
                curveTable.selectRowIndexes(IndexSet(integer: desiredRow),
                                            byExtendingSelection: false)
            } else {
                curveTable.deselectAll(nil)
            }
            isSyncingSelection = false
        }

        let active = lines.first { $0.id == activeID }
        let hasActive = active != nil
        orderPopUp.isEnabled = hasActive
        if let active {
            let index = PointOrder.allCases.firstIndex(of: active.order) ?? 0
            orderPopUp.selectItem(at: index)
            orderHint.stringValue = Self.diagnosisText(for: active)
        } else {
            orderHint.stringValue = "选中一条曲线后,可在这里调整它的取点顺序。"
        }

        let count = active?.points.count ?? 0
        // Asked per curve, not once for the panel: the panel shows the *selected*
        // curve's points, and on a figure with several coordinate systems the
        // selected curve may not be measured in the system the canvas is currently
        // calibrating.
        // Parenthesised on the right because `??` binds tighter than `!=`.
        let calibrated = active.map { self.calibration(for: $0) != nil } ?? (calibration != nil)
        pointHeading.stringValue = hasActive
            ? "数据点 · \(count) 个\(calibrated ? "" : "(未标定,显示像素坐标)")"
            : "数据点"
        pointTable.reloadData()
        pointScroll.isHidden = count == 0
        emptyLabel.isHidden = count > 0
    }

    /// Warns when the current order would draw a line that doubles back — the
    /// failure mode the order setting exists to fix, and one that is invisible
    /// until the data is plotted.
    private static func diagnosisText(for line: CurveLine) -> String {
        guard line.points.count >= 2 else { return "至少需要 2 个点才能形成连线。" }
        let diagnosis = line.orderDiagnosis
        switch line.order {
        case .extraction:
            if diagnosis.isMonotonicInX {
                return "X 单调,连线不会折返。"
            }
            return "⚠️ 连线会折返 \(diagnosis.reversals) 次(X 不是单调的)。"
                + "若曲线本应从左到右,改用「X 升序」。"
        case .reversed:
            if diagnosis.isMonotonicInX { return "已反转顺序,X 保持单调。" }
            return "⚠️ 反转后连线仍会折返 \(diagnosis.reversals) 次。"
        case .ascendingX, .descendingX:
            return "已按 X 排序,连线不会折返(同一 X 的点保持原来的先后)。"
        case .swept:
            // The two things worth knowing here: how far the sweep got, and that
            // it is reversible. A half-swept curve draws a polyline with a
            // visibly jumpy tail, and without this line that looks like damage
            // rather than work in progress.
            let swept = line.sweptPointCount
            if swept >= line.points.count {
                return "已按「点重排」圈刷扫过的先后排列。切回「取点顺序」可还原。"
            }
            return "「点重排」已扫到 \(swept)/\(line.points.count) 点,"
                + "没扫到的排在末尾(那一截连线会跳)。切回「取点顺序」可还原。"
        }
    }

    // MARK: - Actions

    @objc private func addLineClicked(_ sender: Any?) { delegate?.sidebarDidRequestAddLine(self) }

    @objc private func removeLineClicked(_ sender: Any?) {
        guard let activeID else { return }
        delegate?.sidebar(self, didRequestRemoveLine: activeID)
    }

    @objc private func orderChanged(_ sender: NSPopUpButton) {
        guard let activeID,
              let raw = sender.selectedItem?.representedObject as? String,
              let order = PointOrder(rawValue: raw) else { return }
        delegate?.sidebar(self, didSetOrder: order, for: activeID)
    }

    @objc private func visibilityChanged(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < lines.count else { return }
        delegate?.sidebar(self, didSetVisible: sender.state == .on, for: lines[row].id)
    }

    @objc private func nameEdited(_ sender: NSTextField) {
        let row = sender.tag
        guard row >= 0, row < lines.count else { return }
        let name = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        delegate?.sidebar(self, didRenameLine: lines[row].id, to: name)
    }
}

// MARK: - Data sources

extension SidebarView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === curveTable ? lines.count : (activeLinePoints?.count ?? 0)
    }

    private var activeLine: CurveLine? { lines.first { $0.id == activeID } }

    private var activeLinePoints: [PixelPoint]? { activeLine?.orderedPoints }
}

extension SidebarView: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        tableView === curveTable ? curveCell(row: row) : pointCell(column: tableColumn, row: row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === curveTable else { return }
        // Ignore the notification our own row sync provokes; acting on it would
        // bounce the selection back through the delegate for ever.
        guard !isSyncingSelection else { return }
        let row = curveTable.selectedRow
        guard row >= 0, row < lines.count else { return }
        delegate?.sidebar(self, didSelectLine: lines[row].id)
    }

    // MARK: Curve row

    private func curveCell(row: Int) -> NSView? {
        let line = lines[row]
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: curveTable.bounds.width, height: 24))

        let toggle = NSButton(checkboxWithTitle: "", target: self,
                              action: #selector(visibilityChanged(_:)))
        toggle.tag = row
        toggle.state = line.isVisible ? .on : .off
        toggle.toolTip = "显示 / 隐藏这条曲线"
        toggle.frame = NSRect(x: 4, y: 3, width: 18, height: 18)
        cell.addSubview(toggle)

        // The swatch is the sampled curve colour when there is one, so the list
        // and the chart agree about which curve is which.
        let swatch = SwatchView(frame: NSRect(x: 24, y: 5, width: 14, height: 14))
        swatch.color = line.lineColor ?? line.color
        swatch.toolTip = line.lineColor == nil ? "尚未取色" : "已取色"
        cell.addSubview(swatch)

        let name = NSTextField(string: line.name)
        name.isBordered = false
        name.drawsBackground = false
        name.font = .systemFont(ofSize: 12)
        name.tag = row
        name.target = self
        name.action = #selector(nameEdited(_:))
        name.toolTip = "双击可重命名"
        name.frame = NSRect(x: 44, y: 3, width: max(60, cell.bounds.width - 44 - 46), height: 18)
        name.autoresizingMask = [.width]
        cell.addSubview(name)

        let count = PassthroughLabel(labelWithString: "\(line.points.count)")
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.frame = NSRect(x: cell.bounds.width - 44, y: 4, width: 38, height: 16)
        count.autoresizingMask = [.minXMargin]
        cell.addSubview(count)

        return cell
    }

    // MARK: Point row

    /// One row of the point table: the number in a label, the two coordinates in
    /// editable fields.
    ///
    /// The fields are what make the table worth more than a readout — it is the
    /// only place in the app where a coordinate can be made *exact*, because a
    /// marker on screen can be aimed at but never typed at. Fixing one digit of a
    /// mis-read axis value is a two-second job here and a blind nudge of a mouse
    /// anywhere else.
    private func pointCell(column: NSTableColumn?, row: Int) -> NSView? {
        guard let points = activeLinePoints, row < points.count else { return nil }
        let identifier = column?.identifier.rawValue ?? "x"
        let width = column?.width ?? 60
        // In a view-based table the cell view is handed the whole cell rect, so
        // the text has to inset itself or it sits on the column divider.
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: width, height: pointTable.rowHeight))
        let inset: CGFloat = identifier == "index" ? 5 : 7
        let frame = NSRect(x: inset, y: 1, width: max(20, width - inset * 2),
                           height: pointTable.rowHeight - 3)
        let value = text(for: identifier, row: row, points: points)

        if identifier == "index" {
            let label = PassthroughLabel(labelWithString: value)
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.frame = frame
            label.autoresizingMask = [.width]
            cell.addSubview(label)
            return cell
        }

        let field = NSTextField(string: value)
        // The column identifier doubles as the axis, so a commit reads back which
        // of the two numbers is being set without a second lookup table that could
        // disagree with the columns.
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.isEditable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.delegate = self
        field.frame = frame
        field.autoresizingMask = [.width]
        cell.addSubview(field)
        return cell
    }

    /// The commit path, split out so it can be driven without a field editor.
    ///
    /// The real route is `controlTextDidEndEditing`, which needs focus and a
    /// keystroke to fire and therefore cannot be reached head-lessly. Returns the
    /// value that was accepted, or nil when the text was refused — which is what a
    /// test needs to see, and what tells the caller to put the old number back.
    @discardableResult
    func commitPointValue(row: Int, axis: PointCoordinate, text: String) -> Double? {
        guard row >= 0, row < (activeLinePoints?.count ?? 0) else { return nil }
        // `Double` and not a locale-aware parse, deliberately. A comma is a
        // thousands separator as often as it is a decimal point, and reading
        // 「1,000」 as 1.000 would be wrong by a factor of a thousand with nothing
        // on screen to show it. Text the parser will not take is refused, and the
        // old number comes back — a visible outcome.
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        guard delegate?.sidebar(self, didEditPointAt: row, axis: axis, to: value) == true else {
            return nil
        }
        // Reformatted to the model's own rendering — 「1e2」 becomes 100.000000, and
        // a number typed with stray spaces loses them. Deferred by one turn of the
        // run loop because this runs from inside `controlTextDidEndEditing` and
        // would otherwise recreate the very cell that is still unwinding; by the
        // time the block runs the field editor has let go of it.
        DispatchQueue.main.async { [weak self] in
            self?.restorePointCell(row: row, axis: axis)
        }
        return value
    }

    private func text(for identifier: String, row: Int, points: [PixelPoint]) -> String {
        let pixel = points[row]
        switch identifier {
        case "index":
            return "\(row + 1)"
        default:
            // Only the curve's own mapping. `calibration(for:)` is already the
            // panel default when no resolver was given, so there is nothing to
            // fall back to here — and falling back to it would show another
            // system's units for this curve's points.
            guard let line = activeLine,
                  let map = calibration(for: line),
                  let data = try? map.data(fromPixel: pixel) else {
                // Without a calibration the pixel coordinates are still useful —
                // and honest about not being the chart's values.
                return Self.number(identifier == "x" ? pixel.x : pixel.y)
            }
            return Self.number(identifier == "x" ? data.x : data.y)
        }
    }

    /// Reloads one cell, so a refused edit stops showing the refused number.
    ///
    /// One cell rather than the table: a rejection is a local event, and a full
    /// reload would throw away the scroll position and the row selection the user
    /// is in the middle of working with.
    private func restorePointCell(row: Int, axis: PointCoordinate) {
        guard let column = pointTable.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == axis.rawValue
        }) else { return }
        pointTable.reloadData(forRowIndexes: IndexSet(integer: row),
                              columnIndexes: IndexSet(integer: column))
    }

    /// Six significant-ish digits, switching to exponent form at the extremes so
    /// a log axis' small values stay readable rather than printing as 0.000000.
    private static func number(_ value: Double) -> String {
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e6 || magnitude < 1e-4 { return String(format: "%.4e", value) }
        return String(format: "%.6f", value)
    }
}

extension SidebarView: NSTextFieldDelegate {
    /// A typed coordinate, committed. Fires on Return, on Tab and on clicking
    /// away, which between them are every way a user leaves a cell — so there is
    /// no keystroke that loses an edit rather than taking it.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let identifier = field.identifier?.rawValue,
              let axis = PointCoordinate(rawValue: identifier) else { return }
        let row = pointTable.row(for: field)
        guard row >= 0 else { return }
        if commitPointValue(row: row, axis: axis, text: field.stringValue) == nil {
            restorePointCell(row: row, axis: axis)
        }
    }
}

/// One section of the panel: a tinted title band over a bordered body.
///
/// The header is a subview (the caller's own label), positioned to sit exactly
/// on the band. Everything else the caller adds is treated as body and inset by
/// `contentFrame`, so a card's contents line up with each other without every
/// call site repeating the same insets.
private final class CardView: NSView {
    static let headerHeight: CGFloat = 22
    private static let border: CGFloat = 1
    private static let bodyInset: CGFloat = 6

    var headerView: NSView?

    /// Subviews that belong to the body, not the title band.
    var body: [NSView] = []

    override var isFlipped: Bool { true }

    /// The rectangle body contents may use, in the card's own coordinates.
    var contentFrame: NSRect {
        NSRect(x: Self.border + Self.bodyInset,
               y: Self.headerHeight + Self.border + Self.bodyInset,
               width: max(1, bounds.width - (Self.border + Self.bodyInset) * 2),
               height: max(1, bounds.height - Self.headerHeight - (Self.border + Self.bodyInset) * 2))
    }

    override func layout() {
        super.layout()
        headerView?.frame = NSRect(x: Self.border + Self.bodyInset, y: Self.border,
                                   width: max(1, bounds.width - (Self.border + Self.bodyInset) * 2),
                                   height: Self.headerHeight - Self.border)
    }

    override func draw(_ dirtyRect: NSRect) {
        let header = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        SidebarView.headerFill.setFill()
        header.fill()

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: Self.headerHeight, width: bounds.width,
               height: max(0, bounds.height - Self.headerHeight)).fill()

        SidebarView.cardBorder.setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()

        // The line under the title band, drawn from the same colour as the grid
        // so a card's header reads as its first row.
        SidebarView.gridColor.setFill()
        NSRect(x: 0, y: Self.headerHeight - 1, width: bounds.width, height: 1).fill()
    }
}

/// A small filled square showing a curve's colour.
private final class SwatchView: NSView {
    var color: RGB8 = RGB8(r: 0, g: 0, b: 0) { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor(srgbRed: CGFloat(color.r) / 255,
                green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255,
                alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        border.lineWidth = 1
        border.stroke()
    }
}
