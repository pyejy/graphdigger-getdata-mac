import AppKit
import GDCore

/// Which interaction the canvas is currently in. Mirrors the toolbar of the
/// original and the FR-6 tool set.
enum ToolMode: CaseIterable {
    case browse
    case setScale
    case pickLineColor
    case pickBackgroundColor
    case gridDigitize
    case traceDigitize
    case capture
    case eraser
    /// Discards the active curve's points so it can be digitised again.
    case redigitize
    /// Sweeps a ring over the points to renumber them in the order it passed.
    /// The tool for a curve whose points came out in an order that draws a
    /// polyline jumping about the chart — which is every curve that is not
    /// single-valued, since area digitising samples column by column.
    case reorder

    var hint: String {
        switch self {
        case .browse:              return "浏览:滚轮缩放、拖拽平移"
        case .setScale:            return "标定:依次点取 X 轴起始 → X 轴末端 → Y 轴起始 → Y 轴末端"
        case .pickLineColor:       return "取色:点击曲线上的像素"
        case .pickBackgroundColor: return "取色:点击空白背景"
        case .gridDigitize:        return "区域取点:拖出矩形框选曲线"
        case .traceDigitize:       return "自动跟踪:点击曲线起点"
        case .capture:             return "手工取点:逐点点击"
        case .eraser:              return "橡皮擦:圆圈碰到的数据点会被删除,拖拽可连续擦除([ ] 调大小)"
        case .redigitize:          return "重新选点:在曲线上框出要重取的区间,清空后重新取点"
        case .reorder:             return "点重排:用圈扫过曲线,扫到的点按先后重新编号([ ] 调大小)"
        }
    }

    /// Whether the tool works by dragging the shared circle over the points —
    /// the eraser to delete them, 点重排 to renumber them.
    ///
    /// One predicate rather than the same pair of comparisons in the ring's
    /// drawing, the pointer tracking, and the info bar's visibility rule: the
    /// three have to agree, and the last of them is what tells the user whether
    /// the size they are reading applies to anything at all.
    var usesRing: Bool { self == .eraser || self == .reorder }

    /// Whether the tool paints something on the canvas as the pointer moves.
    /// Only these need mouse-move tracking, which costs a redraw per event.
    var tracksPointer: Bool { usesRing || self == .redigitize }

    /// The number this tool works by, which the info bar's right end shows and
    /// lets the user drag, or nil for the tools that have none.
    ///
    /// The mapping is here, beside the tool list, because it is part of what a
    /// tool *is*: a tool that takes points is a tool with a sampling rate, and
    /// two of the three sampling tools were shipping that rate with no way to see
    /// it, let alone set it (网格间距 behind a modal dialog in 操作, and the trace
    /// density not adjustable at all).
    ///
    /// 重新选点 is given the grid spacing too rather than a control of its own:
    /// re-digitising a stretch runs the very same area scan, so it is the same
    /// number, and offering it in one tool and not the other would be the same
    /// bug one tool further along the pipeline.
    var parameter: ToolParameter? {
        switch self {
        case .eraser, .reorder:        return .ringRadius
        case .gridDigitize, .redigitize: return .gridSpacing
        case .traceDigitize:           return .traceSpacing
        case .browse, .setScale, .pickLineColor, .pickBackgroundColor, .capture:
            return nil
        }
    }

    /// What this tool's drag is called in the undo stack.
    ///
    /// A stroke is one action, not one per event, so the name has to describe the
    /// whole gesture: the eraser gets 「擦除」 for a drag that deleted forty points.
    /// The names are the same words the tool's button and its hint use, because
    /// the menu reads them back to the user as 「撤销 擦除」 and any drift between
    /// the two would make the message name something they never pressed.
    ///
    /// 浏览 is here for the one thing it changes: the calibration markers it can
    /// drag. A pan changes no state, so an entry is never recorded for one.
    var undoActionName: String {
        switch self {
        case .browse:              return "移动标定标记"
        case .setScale:            return "标定"
        case .pickLineColor:       return "取曲线颜色"
        case .pickBackgroundColor: return "取背景颜色"
        case .gridDigitize:        return "区域取点"
        case .traceDigitize:       return "自动跟踪"
        case .capture:             return "手工取点"
        case .eraser:              return "擦除"
        case .redigitize:          return "重新选点"
        case .reorder:             return "点重排"
        }
    }
}

/// A number the info bar's right end can show, one at a time, chosen by
/// whichever tool is in hand.
///
/// The strip's right end is where a tool's own setting lives — the place the eye
/// already goes when a tool is selected, and the place that is empty for every
/// tool that has nothing to size. It began as the eraser's circle alone; the two
/// sampling rates were left in the 操作 menu, where the grid spacing hid behind a
/// modal dialog the user never found and the trace density did not exist.
enum ToolParameter: CaseIterable {
    /// The ring tools' circle, in **view points**.
    case ringRadius
    /// Area digitising's and 重新选点's scan line spacing, in **image pixels**.
    case gridSpacing
    /// Auto trace's spacing between kept points, in **image pixels** along the path.
    case traceSpacing

    /// The knob's travel, in the parameter's own unit.
    ///
    /// Taken from the canvas' own bounds rather than written out here: the canvas
    /// is what clamps the value, and a slider offering travel the canvas refuses
    /// is a knob that moves while the number does not.
    var range: ClosedRange<Double> {
        switch self {
        case .ringRadius:
            return Double(CanvasView.eraserMinRadius)...Double(CanvasView.eraserMaxRadius)
        case .gridSpacing:
            return Double(CanvasView.gridSpacingRange.lowerBound)...Double(CanvasView.gridSpacingRange.upperBound)
        case .traceSpacing:
            return Double(CanvasView.traceSpacingRange.lowerBound)...Double(CanvasView.traceSpacingRange.upperBound)
        }
    }

    /// How the readout beside the knob is written — the name and the number.
    ///
    /// The two spacings share one word and one unit because they are the same
    /// quantity: how many pixels apart the samples are. Which sampling they set
    /// is the tool button highlighted above them, and giving the two different
    /// words for the same number would suggest they could not be compared.
    func readout(_ value: Double) -> String {
        let whole = Int(value.rounded())
        switch self {
        case .ringRadius:  return "半径 \(whole)"
        case .gridSpacing: return "间距 \(whole)px"
        case .traceSpacing: return "间距 \(whole)px"
        }
    }

    /// What the control does, for the hover tooltip. Spelled out per parameter
    /// because the readout cannot say it in the width a strip can spare.
    var toolTip: String {
        switch self {
        case .ringRadius:
            return "圆圈半径 —— 碰到圆圈的数据点会被删除(橡皮擦)或重新编号(点重排)。也可以用 [ ] 调整。"
        case .gridSpacing:
            return "网格间距 —— 区域取点/重新选点时,相邻扫描线相隔多少像素。数值越小,点越密。"
        case .traceSpacing:
            return "取点密度 —— 自动跟踪时沿曲线每隔多少像素保留一个点。数值越小越密,1 表示每个像素都取。"
        }
    }
}

/// Told about events that need a window-level response (sheets, menus).
protocol CanvasViewDelegate: AnyObject {
    /// Four reference pixels have been collected; ask the user for their values.
    func canvas(_ canvas: CanvasView, didCollectScalePoints anchors: CalibrationAnchors)
    func canvasDidChangeState(_ canvas: CanvasView)
    func canvas(_ canvas: CanvasView, didFailWith message: String)
    /// A re-digitise pass finished. Separate from the message channel because a
    /// pass that worked has something to report and is not a failure — the info
    /// bar should say what it took and what it put back.
    func canvas(_ canvas: CanvasView, didRedigitize lineName: String, removed: Int, added: Int)
    /// A number the info bar shows changed, and here is its new value.
    ///
    /// Its own channel rather than `canvasDidChangeState` because a slider
    /// reports on every frame of a drag, and that one rebuilds the data panel's
    /// two tables: these are the numbers the strip itself displays, and nothing
    /// outside the readout beside the knob depends on them.
    func canvas(_ canvas: CanvasView, didChangeParameter parameter: ToolParameter, to value: Double)
}

extension CanvasViewDelegate {
    /// Default for the existing callers: a re-digitise pass that has nothing to
    /// say is not a failure.
    func canvas(_ canvas: CanvasView, didRedigitize lineName: String, removed: Int, added: Int) {}
    /// Default for the callers that show no strip readout — the selftest's
    /// canvases among them.
    func canvas(_ canvas: CanvasView, didChangeParameter parameter: ToolParameter, to value: Double) {}
}

/// The image canvas: rendering, zoom/pan, and every point-taking tool.
///
/// All geometry lives in `GDCore`; this class converts events to image space,
/// calls into the digitizers, and draws the result.
final class CanvasView: NSView {

    weak var delegate: CanvasViewDelegate?

    // MARK: - Model

    private(set) var image: NSImage?
    private(set) var buffer: BitmapBuffer?

    /// The source image's own bytes, kept from the moment it was opened.
    ///
    /// A project is saved by writing these rather than a re-encode of `image`,
    /// and the reason is that every stored point is a pixel coordinate into this
    /// image. Decoding a PNG and encoding it again is not guaranteed to return
    /// the same pixels; a shift of a single bit anywhere would leave the
    /// calibration anchors and every curve sitting against a picture that no
    /// longer exists, in a file that looked fine until it was reopened.
    ///
    /// Nil when the image arrived without bytes of its own.
    private(set) var imageData: Data?

    /// The name the image was opened under — the window title, and the stem the
    /// 「项目另存为」 panel offers.
    private(set) var imageName: String?

    private(set) var state = ProjectState()

    /// One mask per curve, keyed by line id.
    ///
    /// A mask is a pure function of (buffer, colour, background, tolerance), so
    /// caching it here is what makes switching between curves and re-digitising
    /// instant instead of re-scanning the whole image every time. Curves are
    /// independent: extracting a red curve and a blue one uses two masks, which
    /// is exactly what `tolerance` alone could not do on a multi-colour chart.
    private var masks: [UUID: ForegroundMask] = [:]

    /// What each cached mask was built from, so a restore can tell which of them
    /// the returned state invalidated instead of re-scanning every image.
    private var maskInputs: [UUID: MaskInput] = [:]

    /// The whole input a curve's mask is derived from: two colours and a
    /// tolerance, which together are a pure function of the image alone.
    private struct MaskInput: Equatable {
        let color: RGB8
        let background: RGB8?
        let tolerance: Double
    }

    /// The mask the next digitising action will use, or nil when the active
    /// curve has no sampled colour yet.
    var activeMask: ForegroundMask? {
        guard let id = state.activeLineID else { return nil }
        return masks[id]
    }

    // MARK: - Undo

    /// One snapshot per user action, so an accidental stroke can be taken back.
    ///
    /// The app had no undo at all, which is why every mutation was written to be
    /// conservative — a sweep stored beside the points rather than replacing
    /// them, an eraser that only ever deletes. Those remain good properties; this
    /// is the general answer underneath them.
    private var history = UndoHistory<ProjectState>()

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    /// What 「撤销」 would take back, for the menu to name the action.
    var undoLabel: String? { history.undoLabel }
    var redoLabel: String? { history.redoLabel }

    // MARK: - Saved baseline

    /// The state as it was when the document was opened or last written out.
    ///
    /// Unsaved changes are a **comparison** against this rather than a flag every
    /// mutation has to remember to set. `ProjectState` is a value type that
    /// compares by content, so the mark cannot drift from what is on screen —
    /// and it gets the undo case right for free: undoing back to the saved state
    /// clears it, because the document genuinely is what is on disk again.
    ///
    /// It lives on the canvas rather than in the window controller because this
    /// is the object that knows when the state changes; a copy held elsewhere
    /// would have to be told, which is the flag problem over again.
    private var savedSnapshot: ProjectState?

    /// Whether a save would capture something the file does not have.
    ///
    /// False with no image: an empty window is not a document with unsaved
    /// changes in it, and asking about one on quit would be pure noise.
    var hasUnsavedChanges: Bool {
        guard image != nil else { return false }
        return state != savedSnapshot
    }

    /// Moves the baseline up to what is on screen, after a save or an open.
    func markSaved() { savedSnapshot = state }

    /// Runs `body` as one undoable step called `label`.
    ///
    /// For the mutations that arrive from a menu, a button or the panel — one
    /// call, one action. A drag does **not** go through here: the eraser and the
    /// reorder brush report on every mouse-moved, and a step per event would fill
    /// the stack with a hundred entries that each undo one pixel of travel. Those
    /// take a snapshot on the press and commit it on the release — see
    /// `beginGesture` / `endGesture` — so one stroke is one undo, which is what
    /// the user means by 上一步.
    ///
    /// Takes the state `inout` rather than reading and writing the property
    /// around the call, because Swift's exclusivity rules forbid calling a method
    /// on `self` that touches `state` while `state` is being mutated. Anything the
    /// body needs from the current state has to be computed before it.
    private func perform(_ label: String, _ body: (inout ProjectState) -> Void) {
        let before = state
        body(&state)
        history.commit(before: before, label: label, now: state)
    }

    /// The state as it stood when the current press began, or nil between
    /// gestures. Overwritten by the next press, so a release that never arrives —
    /// the fourth calibration click goes into a modal sheet and its mouse-up is
    /// swallowed — cannot leak a stale snapshot into the action after it.
    private var gestureBefore: ProjectState?

    private func beginGesture() {
        gestureBefore = state
    }

    /// Closes the gesture and records it as one step.
    private func endGesture(_ label: String) {
        guard let before = gestureBefore else { return }
        gestureBefore = nil
        guard history.commit(before: before, label: label, now: state) else { return }
        // Announces the new entry itself: the stroke's own `canvasDidChangeState`
        // fired *before* this ran, so a menu enabled from that one would still be
        // greyed out with a step sitting on the stack.
        delegate?.canvasDidChangeState(self)
    }

    /// Takes back the last action and returns its name, or nil at the bottom.
    ///
    /// The name is returned rather than announced through a channel of its own
    /// because there is exactly one caller that cares — the menu handler, which
    /// puts it in the status line. A silent success would be indistinguishable
    /// from a dead shortcut.
    @discardableResult
    func undo() -> String? {
        guard let entry = history.undo(now: state) else { return nil }
        restore(entry.state)
        return entry.label
    }

    /// Reapplies the last action taken back, or reports that there is none.
    @discardableResult
    func redo() -> String? {
        guard let entry = history.redo(now: state) else { return nil }
        restore(entry.state)
        return entry.label
    }

    /// Puts a snapshot back and makes everything that hangs off the state agree
    /// with it.
    ///
    /// The three scratch buffers are cleared because they belong to the gesture
    /// that was undone, not to the state that came back: a half-placed
    /// calibration, a ring brush mid-stroke and a rubber band would all be drawn
    /// against a model that no longer has what they were collected from.
    private func restore(_ snapshot: ProjectState) {
        state = snapshot
        pendingScalePoints.removeAll()
        reorder = nil
        reorderLastCentre = nil
        dragRect = nil
        refreshMasks()
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    /// Rebuilds exactly the masks the restored state invalidated.
    ///
    /// Not "rebuild them all": a mask costs a full pass over the image, and most
    /// undos — a stroke erased, a sweep taken back — do not touch any colour. The
    /// ones that do are covered by comparing against what each cached mask was
    /// built from, which is also what keeps a curve whose colour was undone from
    /// going on being digitised through the mask of the colour it no longer has.
    private func refreshMasks() {
        guard let buffer else {
            masks.removeAll()
            maskInputs.removeAll()
            return
        }
        var fresh: [UUID: ForegroundMask] = [:]
        var inputs: [UUID: MaskInput] = [:]
        for line in state.lines {
            guard let color = line.lineColor else { continue }
            let input = MaskInput(color: color, background: line.backgroundColor,
                                  tolerance: line.colorTolerance)
            inputs[line.id] = input
            if maskInputs[line.id] == input, let cached = masks[line.id] {
                fresh[line.id] = cached
            } else {
                fresh[line.id] = ForegroundMask.build(from: buffer,
                                                      lineColor: color,
                                                      tolerance: line.colorTolerance,
                                                      backgroundColor: line.backgroundColor)
            }
        }
        masks = fresh
        maskInputs = inputs
    }

    /// Pixels collected so far while in `.setScale`. Cleared by the delegate
    /// once the values are entered (or the user cancels).
    private(set) var pendingScalePoints: [PixelPoint] = []

    private var transform = ViewTransform()

    var tool: ToolMode = .browse {
        didSet {
            pendingScalePoints.removeAll()
            dragRect = nil
            hoverPoint = nil
            // A sweep is one tool's session. Leaving it half-loaded while the
            // user does something else would let the next stroke carry on
            // numbering from a sequence that no longer matches what is on
            // screen; the model keeps the record, so nothing is lost by
            // reloading it when the brush comes back.
            reorder = nil
            reorderLastCentre = nil
            if !tool.tracksPointer { window?.acceptsMouseMovedEvents = false }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            delegate?.canvasDidChangeState(self)
        }
    }

    /// Radius of the eraser's ring, in **view points**.
    ///
    /// View points rather than image pixels because the ring is a piece of UI:
    /// it has to stay the same size on screen at every zoom, and the number the
    /// user reads in the info bar has to mean something they can see. The hit
    /// test converts it into image space, where the points are.
    ///
    /// Clamping lives in a computed setter rather than a `didSet` that assigns
    /// to the property: an assignment inside `didSet` runs `didSet` again, so the
    /// clamping form has to compare before it writes or it never terminates. A
    /// setter has no such rule, so the clamp is a plain expression here and the
    /// only guard needed is the one against a pointless redraw.
    var eraserRadius: CGFloat {
        get { storedEraserRadius }
        set {
            let clamped = min(Self.eraserMaxRadius, max(Self.eraserMinRadius, newValue))
            guard clamped != storedEraserRadius else { return }
            storedEraserRadius = clamped
            needsDisplay = true
            delegate?.canvas(self, didChangeParameter: .ringRadius, to: Double(clamped))
        }
    }
    private var storedEraserRadius: CGFloat = CanvasView.eraserDefaultRadius

    /// The range the ring may take, in view points, and how far the `[` `]` keys
    /// step within it. Lives here rather than on the info bar because the canvas
    /// is the thing that has to honour them — and because the slider's own range
    /// is checked against these, so a control offering travel the canvas refuses
    /// cannot go unnoticed.
    static let eraserDefaultRadius: CGFloat = 18
    static let eraserRadiusStep: CGFloat = 4
    static let eraserMinRadius: CGFloat = 6
    static let eraserMaxRadius: CGFloat = 120

    /// Travel of the two sampling spacings, in image pixels, and where each
    /// starts.
    ///
    /// One is the finest sampling either digitizer has: one scan line per pixel
    /// column, or one point per pixel of path. Forty is the coarsest worth a
    /// knob — past it a 600px-wide region yields fewer points than the curve has
    /// bends, so the setting stops describing anything anyone would pick on
    /// purpose, and the slider's useful half would be squeezed into its first
    /// tenth. The two share a range because they are the same kind of number;
    /// only their defaults differ, the trace having started out at every pixel.
    ///
    /// The defaults are duplicated in `ProjectState`'s initialiser, which cannot
    /// see this file. A selftest asserts the two agree, which is the only thing
    /// that stops them drifting.
    static let gridSpacingRange = 1...40
    static let gridSpacingDefault = 8
    static let traceSpacingRange = 1...40
    static let traceSpacingDefault = 1

    /// Grows or shrinks the ring, for the `[` `]` keys. The slider in the info
    /// bar sets the radius outright instead.
    func changeEraserRadius(by delta: CGFloat) {
        eraserRadius += delta
    }

    // MARK: - 点重排 (sweep reorder)

    /// The brush's numbering for the sweep in progress, or nil between strokes.
    ///
    /// Held here as well as in the model because the model stores a plain
    /// `[Int]` — cheap to persist and to draw — while the running stroke needs
    /// the membership set to answer "has this point been numbered yet?" without
    /// rescanning. Reloaded from the model at the start of every stroke, so
    /// switching curves and coming back continues where the user left off.
    private var reorder: SweepReorder?

    /// Where the brush was at the previous event. The leg between this and the
    /// current position is what gets resampled.
    private var reorderLastCentre: PixelPoint?

    /// The reorder ring's radius, in view points.
    ///
    /// The eraser's, deliberately shared: both tools are "a ring you drag over
    /// the points", and the number the user reads in the info bar would be a
    /// second thing to remember for no gain. Sharing it also means `[` and `]`
    /// already resize this tool with no further wiring.
    var reorderRadius: CGFloat { eraserRadius }

    /// The ring's radius converted into image pixels, where the points live.
    ///
    /// Shared by both ring tools. The conversion is the same one the eraser has
    /// always made, and for the same reason: the ring is drawn in view points so
    /// it stays a constant size on screen, while the points it tests against are
    /// in image pixels. At a zoom other than 1:1 a tool that forgot this would
    /// still look right and take the wrong area — a mistake this project has made
    /// once already, which is why `viewScale` carries a note about it.
    private var ringImageRadius: Double {
        Double(eraserRadius) / max(transform.scale, 0.0001)
    }

    /// How far the sweep has got, or nil when this is not the active tool.
    /// Drives the info bar's progress readout.
    var reorderProgress: (swept: Int, total: Int)? {
        guard tool == .reorder, let line = state.activeLine, line.points.count >= 2 else { return nil }
        let swept = SweepReorder(pointCount: line.points.count,
                                 sequence: line.sweptOrder ?? []).swept
        return (swept, line.points.count)
    }

    /// Starts a stroke: loads the curve's existing numbering and takes whatever
    /// is already under the ring.
    ///
    /// Numbering continues from what is stored rather than restarting at 1, so a
    /// sweep can be done in as many strokes as the user likes. Pressing without
    /// moving has no direction of travel to order a catch by, so this first
    /// capture ranks by distance from the centre — good enough to fill a gap the
    /// brush skipped, and documented as such, since it cannot say which of the
    /// caught points came first.
    private func beginReorderStroke(at p: PixelPoint) {
        guard let line = state.activeLine, line.points.count >= 2 else { return }
        var brush = SweepReorder(pointCount: line.points.count, sequence: line.sweptOrder ?? [])
        brush.capture(points: line.points, around: p, radius: ringImageRadius, direction: nil)
        reorder = brush
        reorderLastCentre = p
        recordSweep()
    }

    /// Extends the stroke to `p`, numbering everything the ring passed over on
    /// the way. The legs between events are resampled inside `SweepReorder`, so
    /// a fast drag numbers the same points as a slow one.
    private func extendReorderStroke(to p: PixelPoint) {
        guard var brush = reorder, let last = reorderLastCentre, let line = state.activeLine else { return }
        brush.sweep(points: line.points, from: last, to: p, radius: ringImageRadius)
        reorder = brush
        reorderLastCentre = p
        recordSweep()
    }

    /// Publishes the brush's numbering to the model, and with it to the panel and
    /// the canvas. Called after every capture rather than at the end of the
    /// stroke, which is what makes the point table and the sequence numbers
    /// update while the brush is still moving.
    private func recordSweep() {
        guard let brush = reorder, let id = state.activeLineID else { return }
        state.recordSweep(brush.sequence, for: id)
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    /// Drops a curve's sweep and puts it back in its extraction order.
    func clearReorder(for id: UUID) {
        perform("清除点重排") { $0.clearSweep(for: id) }
        reorder = nil
        reorderLastCentre = nil
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    // MARK: - Interaction scratch

    private var dragRect: CGRect?          // grid/redigitise rubber band, in image space
    private var isPanning = false
    private var lastPanPoint: CGPoint?
    private var activeHandle: CalibrationHandle?
    /// Where the pointer is, in image space, while a ring-drawing tool is active.
    private var hoverPoint: PixelPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Image

    /// Puts a new picture on the canvas, throwing away the curves drawn on the
    /// one before it.
    ///
    /// - Parameters:
    ///   - data: the bytes the image was decoded from, kept verbatim for the next
    ///     project save. Optional because not every image arrives from a file.
    ///   - name: what to call the image in the title bar.
    ///
    /// Returns false when the image cannot be turned into a bitmap, and leaves
    /// the canvas exactly as it was. `NSImage` decodes lazily, so it accepts
    /// bytes it will later fail to draw — a half-copied file, a truncated PNG —
    /// and the failure only shows up when something asks for the pixels. Asking
    /// for them here is what turns that into a refusal the caller can report,
    /// instead of a window with curves on it and no picture behind them.
    @discardableResult
    func load(image: NSImage, data: Data? = nil, name: String? = nil) -> Bool {
        guard install(image: image, data: data, name: name) else { return false }
        state.lines.removeAll()
        state.activeLineID = nil
        // The snapshots describe a chart that is no longer on screen. Restoring
        // one would put points back onto a different picture, at coordinates that
        // meant something in the old one.
        history.reset()

        // The background is sampled once here and inherited by every curve the
        // user creates afterwards, so extracting a curve needs one click on the
        // curve rather than one on the curve and another on the background.
        state.defaultBackgroundColor = buffer.flatMap { BackgroundDetector.detect(in: $0) }

        // Nothing has been done to this picture yet, so nothing is unsaved.
        // Opening a chart is not an edit; the first one comes from the user.
        savedSnapshot = state

        needsDisplay = true
        delegate?.canvasDidChangeState(self)
        return true
    }

    /// Restores a project file: its image, its calibration and every curve.
    ///
    /// Returns false — and changes nothing — when the bytes the file carries are
    /// not an image this machine can decode. That is the one failure worth
    /// reporting separately, because it is the file's *image* that is at fault
    /// rather than the file, and the container having parsed only means the
    /// header was intact.
    ///
    /// The state is installed **whole**, not merged into whatever was on screen.
    /// A project is a complete description of a session, so opening one is a
    /// replacement; merging would leave the previous chart's curves behind under
    /// the new one's calibration, which is a combination that never existed and
    /// cannot be undone into anything sensible.
    @discardableResult
    func load(project: ProjectDocument) -> Bool {
        guard let image = NSImage(data: project.imageData),
              install(image: image, data: project.imageData,
                      name: project.header.image.fileName) else { return false }
        state = project.header.state

        // A corrupt or hand-edited file can name an active curve that is not in
        // its own list. Left alone, the panel would show nothing selected while
        // the model went on claiming a curve was, and the tools that act on
        // 「当前曲线」 would silently do nothing. Falling back is the honest
        // repair: the curves are all there, only the pointer was wrong.
        if let id = state.activeLineID, !state.lines.contains(where: { $0.id == id }) {
            state.activeLineID = state.lines.first?.id
        }

        // Nothing on the stack belongs to this document: the snapshots describe
        // the previous session, and ⌘Z into them would splice two charts
        // together. Opened as the bottom of a fresh history.
        history.reset()
        // Built from scratch rather than reused: the mask cache is keyed by curve
        // id and holds what each was built from, and a reopened file's curves
        // have new ids against an image that was never in this view.
        refreshMasks()

        // What the file holds is, by definition, saved. Everything the user does
        // from here is the difference the window will offer to keep.
        savedSnapshot = state

        needsDisplay = true
        delegate?.canvasDidChangeState(self)
        return true
    }

    /// The document that would recreate what is on screen, or nil with no image.
    ///
    /// Lives here rather than in the window controller because the three things
    /// it needs — the image bytes, the name they came in under, and the state —
    /// are all owned by this view, and a caller assembling them from outside
    /// would be a second place that has to know what a project contains.
    func projectDocument(appVersion: String? = nil, savedAt: Date = Date()) -> ProjectDocument? {
        guard let imageData, let buffer else { return nil }
        return ProjectDocument(
            header: ProjectHeader(
                appVersion: appVersion,
                savedAt: savedAt,
                image: ProjectImageInfo(fileName: imageName,
                                        pixelWidth: buffer.width,
                                        pixelHeight: buffer.height),
                state: state),
            imageData: imageData)
    }

    /// The half of loading that the two entry points share: decode, cache the
    /// bytes, and drop everything derived from the picture that just went away.
    ///
    /// Reports whether a bitmap came out, and **assigns nothing when it did
    /// not** — the decode happens before the first assignment for exactly that
    /// reason, so a caller that is going to refuse can refuse without having
    /// already replaced what was on screen with a document it cannot show.
    private func install(image: NSImage, data: Data?, name: String?) -> Bool {
        guard let decoded = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .flatMap(Self.makeBuffer) else { return false }
        self.image = image
        self.imageData = data
        self.imageName = name
        self.buffer = decoded
        masks.removeAll()
        maskInputs.removeAll()
        return true
    }

    /// Fits the current image into the view, recentring it. Called on load and
    /// by View ▸ Fit / the 适配窗口 button.
    ///
    /// Reports whether anything moved, so the caller can tell "already fitted"
    /// from "did nothing".
    @discardableResult
    func zoomToFit() -> Bool {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return false }
        guard bounds.width > 0, bounds.height > 0 else { return false }

        let previous = transform
        transform.fit(imageWidth: Int(size.width), imageHeight: Int(size.height),
                      viewWidth: Double(bounds.width), viewHeight: Double(bounds.height))
        guard transform != previous else { return false }
        needsDisplay = true
        return true
    }

    /// Human-readable zoom, for the status line.
    var zoomDescription: String {
        guard image != nil else { return "" }
        return String(format: "缩放 %.0f%%", transform.scale * 100)
    }

    /// View points per image pixel — the current zoom.
    ///
    /// The eraser's circle and the re-digitise band are measured on screen and
    /// applied in image space, so both divide by this. Exposed so the selftest
    /// can show the conversion actually happens: at a zoom other than 1:1 a
    /// tool that forgot to divide would still look right at 100% and wipe the
    /// wrong area everywhere else.
    var viewScale: Double { transform.scale }

    /// Where an image pixel sits in this view, so a caller can aim an event at a
    /// pixel rather than a screen position. The selftest drives the real mouse
    /// handlers this way; at a zoom other than 1:1 the two coordinates differ,
    /// which is exactly the case worth being able to construct.
    func viewPoint(fromImage p: PixelPoint) -> CGPoint { transform.viewPoint(fromImage: p) }

    func zoomIn()  { transform.zoom(by: 1.25, around: CGPoint(x: bounds.midX, y: bounds.midY)); needsDisplay = true }
    func zoomOut() { transform.zoom(by: 1 / 1.25, around: CGPoint(x: bounds.midX, y: bounds.midY)); needsDisplay = true }

    override func setFrameSize(_ newSize: NSSize) {
        let wasFitted = isShowingWholeImage
        super.setFrameSize(newSize)
        if wasFitted { zoomToFit() }
    }

    private var isShowingWholeImage: Bool {
        guard let size = image?.size, size.width > 0 else { return false }
        return abs(Double(size.width) * transform.scale - Double(bounds.width)) < 40
    }

    // MARK: - State mutations used by menus

    /// Installs a calibration built from the four clicked anchors.
    func applyCalibration(anchors: CalibrationAnchors,
                          xStartValue: Double, xEndValue: Double,
                          yStartValue: Double, yEndValue: Double,
                          xIsLogarithmic: Bool, yIsLogarithmic: Bool) {
        perform("标定") {
            $0.applyCalibration(anchors: anchors,
                                xStartValue: xStartValue, xEndValue: xEndValue,
                                yStartValue: yStartValue, yEndValue: yEndValue,
                                xIsLogarithmic: xIsLogarithmic, yIsLogarithmic: yIsLogarithmic)
        }
        pendingScalePoints.removeAll()
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    /// Replaces the mapping's numbers, leaving the four markers where they are.
    /// The edit-values path: correcting a figure is not re-tracing an axis.
    func updateCalibrationValues(_ map: CalibrationMap) {
        perform("修改标定数值") { $0.installCalibration(map) }
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    /// Enters calibration, or refuses to.
    ///
    /// Once a coordinate system exists, starting another must not quietly throw
    /// it away — the user asked for exactly that guarantee. Returning false
    /// leaves the calibration, the points and the active tool untouched; the
    /// caller asks the user and comes back with `force: true`. Kept here rather
    /// than only in the menu handler so the refusal is testable without driving
    /// a modal alert.
    @discardableResult
    func beginCalibration(force: Bool) -> Bool {
        if state.calibration != nil && !force { return false }
        if force { clearCalibration() }
        tool = .setScale
        return true
    }

    func cancelPendingScale() {
        pendingScalePoints.removeAll()
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    /// Drops the calibration so it can be redone from scratch. Extracted points
    /// are kept — they are stored in pixel space and stay valid.
    func clearCalibration() {
        perform("清除标定") { $0.clearCalibration() }
        pendingScalePoints.removeAll()
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    /// Prompt for the next click while picking anchors.
    var scalePrompt: String? {
        guard tool == .setScale else { return nil }
        let labels = CalibrationAnchors.clickOrder
        let step = min(pendingScalePoints.count, labels.count - 1)
        return "标定 \(step + 1)/\(labels.count):点取\(labels[step])"
    }

    /// Names of the anchors already placed, for the on-canvas prompts.
    private var placedAnchorLabels: [String] {
        Array(CalibrationAnchors.clickOrder.prefix(pendingScalePoints.count))
    }

    func clearActiveLinePoints() {
        guard let id = state.activeLineID else { return }
        perform("清除曲线上的点") { $0.replacePoints(of: id, with: []) }
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    /// Palette used for curves whose colour has not been sampled yet. The
    /// sampled colour replaces the swatch the moment the user clicks the curve.
    static let palette: [RGB8] = [
        RGB8(r: 214, g: 39, b: 40), RGB8(r: 31, g: 119, b: 180),
        RGB8(r: 44, g: 160, b: 44), RGB8(r: 255, g: 127, b: 14),
        RGB8(r: 148, g: 103, b: 189), RGB8(r: 140, g: 86, b: 75),
    ]

    @discardableResult
    func addLine() -> UUID {
        let color = nextColor()
        var id = UUID()
        perform("新增曲线") { id = $0.addLine(color: color) }
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
        return id
    }

    /// Selecting a curve is *not* an undo step. It is navigation — which curve
    /// the next action applies to — and putting it on the stack would mean the
    /// first 「撤销」 after a click in the panel merely moved the selection back,
    /// taking back nothing the user meant to take back.
    func selectLine(id: UUID) {
        state.activeLineID = id
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    func renameLine(id: UUID, to name: String) {
        perform("重命名曲线") { $0.rename(id: id, to: name) }
        delegate?.canvasDidChangeState(self)
    }

    func setOrder(_ order: PointOrder, for id: UUID) {
        perform("切换取点顺序") { $0.setOrder(order, for: id) }
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    func setVisible(_ visible: Bool, for id: UUID) {
        guard let index = state.lines.firstIndex(where: { $0.id == id }) else { return }
        perform("显示/隐藏曲线") { $0.lines[index].isVisible = visible }
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    func removeLine(id: UUID) {
        perform("删除曲线") { $0.removeLine(id: id) }
        // After the restore point, not before: an undo puts the curve back, and
        // the mask has to be gone *now* either way.
        masks[id] = nil
        maskInputs[id] = nil
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    func clearPoints(of id: UUID) {
        perform("清除曲线上的点") { $0.replacePoints(of: id, with: []) }
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    func removeActiveLine() {
        guard let id = state.activeLineID else { return }
        removeLine(id: id)
    }

    /// Grid spacing for area digitising, in pixels. Densifies sampling as it drops.
    ///
    /// Clamped to the range the control offers, and the clamp is the contract:
    /// a value outside it would leave the readout showing a number the knob
    /// cannot be dragged back to, so there is nothing here for the caller to
    /// guard against.
    ///
    /// Reports through `didChangeParameter` rather than `canvasDidChangeState`:
    /// the strip's knob calls this on every frame of a drag, and the latter
    /// rebuilds the data panel's two tables — while neither spacing shows up in
    /// them. The one other caller, the menu's dialog, refreshes the strip itself.
    func setGridSpacing(_ value: Int) {
        let clamped = min(Self.gridSpacingRange.upperBound,
                          max(Self.gridSpacingRange.lowerBound, value))
        guard clamped != state.gridSpacing else { return }
        state.gridSpacing = clamped
        delegate?.canvas(self, didChangeParameter: .gridSpacing, to: Double(clamped))
    }

    /// How far apart auto trace keeps the points it walks through, in pixels of
    /// travel along the path.
    ///
    /// Applied when a trace runs — it thins the path that walk produced rather
    /// than steering the walk, so changing it re-samples a curve without changing
    /// which way the trace went. See `TraceDigitizer.decimate`.
    func setTraceSpacing(_ value: Int) {
        let clamped = min(Self.traceSpacingRange.upperBound,
                          max(Self.traceSpacingRange.lowerBound, value))
        guard clamped != state.traceSpacing else { return }
        state.traceSpacing = clamped
        delegate?.canvas(self, didChangeParameter: .traceSpacing, to: Double(clamped))
    }

    /// A parameter's current value. The canvas owns these numbers — it is the one
    /// that honours and clamps them — and the strip reports them.
    func value(of parameter: ToolParameter) -> Double {
        switch parameter {
        case .ringRadius:   return Double(eraserRadius)
        case .gridSpacing:  return Double(state.gridSpacing)
        case .traceSpacing: return Double(state.traceSpacing)
        }
    }

    /// Applies a value the strip's knob reported. Whole numbers only: these are
    /// sizes being chosen, not measurements, and a fractional one would put a
    /// number in the readout the knob cannot be dragged back to.
    ///
    /// A method on the canvas rather than a switch in `AppDelegate` so the
    /// selftest can drive the same conversion the app does. A copy of it in the
    /// test would assert the copy.
    func setValue(_ value: Double, of parameter: ToolParameter) {
        let whole = value.rounded()
        switch parameter {
        case .ringRadius:   eraserRadius = CGFloat(whole)
        case .gridSpacing:  setGridSpacing(Int(whole))
        case .traceSpacing: setTraceSpacing(Int(whole))
        }
    }

    /// Colour-distance tolerance for the active curve. Rebuilds that curve's
    /// mask so the change takes effect on the next digitise without re-sampling.
    func setColorTolerance(_ value: Double) {
        guard let id = state.activeLineID else { return }
        perform("颜色容差") { $0.setColorTolerance(value, for: id) }
        rebuildMask(for: id)
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    /// The active curve's tolerance, for the menu's current-value field.
    var activeColorTolerance: Double {
        state.activeLine?.colorTolerance ?? state.defaultColorTolerance
    }

    // MARK: - Masks

    /// Rebuilds one curve's mask from its own colour, background and tolerance.
    ///
    /// Records what it built it from as well, so that `refreshMasks` — which runs
    /// after an undo — can tell this one apart from the ones the restored state
    /// invalidated, and skip the full pass over the image for the rest.
    private func rebuildMask(for id: UUID) {
        guard let buffer, let line = state.lines.first(where: { $0.id == id }),
              let lineColor = line.lineColor else {
            masks[id] = nil
            maskInputs[id] = nil
            return
        }
        masks[id] = ForegroundMask.build(from: buffer,
                                         lineColor: lineColor,
                                         tolerance: line.colorTolerance,
                                         backgroundColor: line.backgroundColor)
        maskInputs[id] = MaskInput(color: lineColor, background: line.backgroundColor,
                                   tolerance: line.colorTolerance)
    }

    /// Makes sure the active curve exists and has a mask, creating a curve when
    /// the user starts digitising without having added one.
    @discardableResult
    private func ensureActiveLine() -> UUID {
        if let id = state.activeLineID, state.lines.contains(where: { $0.id == id }) { return id }
        return state.addLine(color: nextColor())
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            drawPlaceholder()
            return
        }

        // Draw the bitmap through the transform so zoom stays crisp.
        let origin = transform.viewPoint(fromImage: PixelPoint(x: 0, y: 0))
        let size = NSSize(width: Double(cg.width) * transform.scale,
                          height: Double(cg.height) * transform.scale)
        let target = NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height)

        NSGraphicsContext.current?.imageInterpolation =
            transform.scale >= 3 ? .none : .high
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            .draw(in: target, from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)

        drawCalibrationOverlay()
        drawCurves()
        drawPendingScalePoints()
        drawDragRect()
        drawToolRing()
    }

    private func drawPlaceholder() {
        let text = "打开一张图表图片开始  (⌘O)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                              y: bounds.midY - size.height / 2),
                  withAttributes: attributes)
    }

    // MARK: - Calibration overlay

    /// The four adjustable anchors, plus the two axis rules derived from them.
    ///
    /// Each rule is drawn between its own axis' two anchors, which is exactly
    /// the geometry the user traced — so a mistake is visible as a rule pointing
    /// the wrong way, or as one that misses the chart's own axis line.
    enum CalibrationHandle: CaseIterable {
        case xStart, xEnd, yStart, yEnd
    }

    static let xAxisColor = NSColor.systemBlue
    static let yAxisColor = NSColor.systemTeal

    /// Current position of a handle in image space. Falls back to anchors
    /// synthesised from the calibration when none were kept (a map built before
    /// `CalibrationAnchors` existed).
    func handlePosition(_ handle: CalibrationHandle,
                        _ calibration: CalibrationMap) -> PixelPoint {
        let anchors = state.calibrationAnchors ?? CalibrationAnchors(fallbackFrom: calibration)
        switch handle {
        case .xStart: return anchors.xStart
        case .xEnd:   return anchors.xEnd
        case .yStart: return anchors.yStart
        case .yEnd:   return anchors.yEnd
        }
    }

    /// Handle under a view point, if any. Radius is in view space so the target
    /// stays the same size at every zoom level.
    private func handle(at viewPoint: CGPoint) -> CalibrationHandle? {
        guard let calibration = state.calibration else { return nil }
        let radius: CGFloat = 11
        for handle in CalibrationHandle.allCases {
            let v = transform.viewPoint(fromImage: handlePosition(handle, calibration))
            if hypot(v.x - viewPoint.x, v.y - viewPoint.y) <= radius { return handle }
        }
        return nil
    }

    /// Moves one anchor and recomputes the mapping.
    ///
    /// Each handle moves only its own axis' own end. The old shared origin moved
    /// both axes' minima at once; now that the axes are independent there is no
    /// handle that can drag two axes at the same time, which is what makes it
    /// impossible to leave them inconsistent with each other.
    func dragHandle(_ handle: CalibrationHandle, to imagePoint: PixelPoint) {
        guard var calibration = state.calibration else { return }
        var anchors = state.calibrationAnchors ?? CalibrationAnchors(fallbackFrom: calibration)

        switch handle {
        case .xStart:
            if abs(imagePoint.x - calibration.x.pixelMax) < 1 { return }
            calibration.x.pixelMin = imagePoint.x
            anchors.xStart = imagePoint
        case .xEnd:
            if abs(imagePoint.x - calibration.x.pixelMin) < 1 { return }
            calibration.x.pixelMax = imagePoint.x
            anchors.xEnd = imagePoint
        case .yStart:
            if abs(imagePoint.y - calibration.y.pixelMax) < 1 { return }
            calibration.y.pixelMin = imagePoint.y
            anchors.yStart = imagePoint
        case .yEnd:
            if abs(imagePoint.y - calibration.y.pixelMin) < 1 { return }
            calibration.y.pixelMax = imagePoint.y
            anchors.yEnd = imagePoint
        }

        state.calibration = calibration
        state.calibrationAnchors = anchors
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    /// How close the pointer has to come to a handle before the set comes back,
    /// in view points. Deliberately larger than the 11pt grab radius: a target
    /// that only appears once it is already grabbable is a target you cannot
    /// aim at.
    static let handleRevealRadius: CGFloat = 22

    /// Whether the four handles belong on screen right now.
    ///
    /// They are drag targets for nudging an axis, not part of the chart. Once the
    /// coordinate system is confirmed they land right on top of the data — four
    /// discs the size of a data marker, each trailing a value label — and the
    /// pixel readout they used to carry means nothing after 标定. The user's
    /// report was exactly that: a chart that is being read with two large
    /// coloured discs and an `@(116, 488)` sitting in the middle of it.
    ///
    /// So they are drawn only while they are actionable: during 标定 itself,
    /// while one is being dragged, or once the pointer has come within reach of
    /// one. The reveal is what keeps them reachable rather than merely gone —
    /// and it brings back the whole set, not just the nearest handle, because a
    /// lone disc says nothing about which axis it belongs to.
    private var showsCalibrationHandles: Bool {
        if tool == .setScale { return true }
        if activeHandle != nil { return true }
        guard let calibration = state.calibration, let hover = hoverPoint else { return false }
        let h = transform.viewPoint(fromImage: hover)
        return CalibrationHandle.allCases.contains { handle in
            let v = transform.viewPoint(fromImage: handlePosition(handle, calibration))
            return hypot(v.x - h.x, v.y - h.y) <= Self.handleRevealRadius
        }
    }

    private func drawCalibrationOverlay() {
        guard let calibration = state.calibration else { return }
        drawRules(calibration)
        drawTicks(calibration)
        guard showsCalibrationHandles else { return }
        drawHandles(calibration)
    }

    private func drawRules(_ calibration: CalibrationMap) {
        // Each axis is its own segment. They need not share an end — that is the
        // whole reason for four anchors — so there is no common corner to draw
        // from any more.
        drawRule(from: handlePosition(.xStart, calibration),
                 to: handlePosition(.xEnd, calibration), color: Self.xAxisColor)
        drawRule(from: handlePosition(.yStart, calibration),
                 to: handlePosition(.yEnd, calibration), color: Self.yAxisColor)
    }

    private func drawRule(from a: PixelPoint, to b: PixelPoint, color: NSColor) {
        let p = transform.viewPoint(fromImage: a)
        let q = transform.viewPoint(fromImage: b)
        color.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.move(to: p)
        path.line(to: q)
        path.stroke()
    }

    /// Tick marks along both rules, labelled with the values they represent.
    /// A mis-entered value shows up immediately as ticks that miss the chart's
    /// own grid — the only reliable way to see that a calibration is wrong.
    ///
    /// Ticks ride their own rule: the cross-axis coordinate is interpolated
    /// between that rule's two anchors rather than taken from a shared origin.
    /// A rule drawn slightly off-square, or one whose two ends sit at different
    /// heights, would otherwise have its ticks float away from the line they
    /// are supposed to mark.
    private func drawTicks(_ calibration: CalibrationMap) {
        let xStart = handlePosition(.xStart, calibration)
        let xEnd = handlePosition(.xEnd, calibration)
        let yStart = handlePosition(.yStart, calibration)
        let yEnd = handlePosition(.yEnd, calibration)

        let xRange = min(xStart.x, xEnd.x)...max(xStart.x, xEnd.x)
        for tick in calibration.x.ticks(overPixelRange: xRange) {
            let row = Self.interpolate(tick.pixel, from: xStart.x, to: xEnd.x,
                                       startValue: xStart.y, endValue: xEnd.y)
            let v = transform.viewPoint(fromImage: PixelPoint(x: tick.pixel, y: row))
            let length: CGFloat = tick.isMajor ? 9 : 5
            Self.xAxisColor.withAlphaComponent(tick.isMajor ? 0.95 : 0.55).setStroke()
            let path = NSBezierPath()
            path.lineWidth = tick.isMajor ? 1.5 : 1
            path.move(to: CGPoint(x: v.x, y: v.y - length))
            path.line(to: CGPoint(x: v.x, y: v.y + length))
            path.stroke()
            if tick.isMajor {
                labelTick(trim(tick.value), at: CGPoint(x: v.x, y: v.y + 12),
                          color: Self.xAxisColor)
            }
        }

        let yRange = min(yStart.y, yEnd.y)...max(yStart.y, yEnd.y)
        for tick in calibration.y.ticks(overPixelRange: yRange) {
            let column = Self.interpolate(tick.pixel, from: yStart.y, to: yEnd.y,
                                          startValue: yStart.x, endValue: yEnd.x)
            let v = transform.viewPoint(fromImage: PixelPoint(x: column, y: tick.pixel))
            let length: CGFloat = tick.isMajor ? 9 : 5
            Self.yAxisColor.withAlphaComponent(tick.isMajor ? 0.95 : 0.55).setStroke()
            let path = NSBezierPath()
            path.lineWidth = tick.isMajor ? 1.5 : 1
            path.move(to: CGPoint(x: v.x - length, y: v.y))
            path.line(to: CGPoint(x: v.x + length, y: v.y))
            path.stroke()
            if tick.isMajor {
                let text = trim(tick.value)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: Self.yAxisColor,
                ]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: v.x - size.width - 12, y: v.y - size.height / 2),
                          withAttributes: attributes)
            }
        }
    }

    /// Linear interpolation with a guard for a degenerate span, so a rule whose
    /// two anchors share the cross-axis coordinate (or coincide) returns the
    /// start rather than dividing by zero.
    ///
    /// Static and internal because the rule it serves is worth pinning without a
    /// rendered frame: the four-anchor scheme made the two axes' cross-axis
    /// coordinates independent, so a tick's row is no longer simply "the X
    /// rule's row" and has to be interpolated along the rule.
    static func interpolate(_ t: Double, from a: Double, to b: Double,
                            startValue: Double, endValue: Double) -> Double {
        guard abs(b - a) > 1e-9 else { return startValue }
        return startValue + (t - a) / (b - a) * (endValue - startValue)
    }

    /// The text a handle carries: the numbered step and the value that anchor
    /// maps to, and nothing else.
    ///
    /// It used to append `@(x, y)` — the anchor's pixel — which was worth reading
    /// while the four clicks were being placed and worth nothing afterwards: the
    /// pixel is what the calibration already encoded, and the user has no use for
    /// it once the axis reads in chart units. The user's words were that it is
    /// meaningless. It was also the widest part of the pill, so leaving it out is
    /// most of what makes the label small.
    ///
    /// Static and internal so the check that the readout stays out can pin the
    /// string directly. It is a question about characters, not about rendering,
    /// and a width measured off a frame would be measuring the dashed X rule
    /// running along the label's own row as much as the label.
    static func handleLabel(step: String, value: String) -> String {
        "\(step) \(value)"
    }

    /// The four handles, as discs with a value label.
    private func drawHandles(_ calibration: CalibrationMap) {
        let entries: [(CalibrationHandle, String, NSColor, String)] = [
            (.xStart, "①", Self.xAxisColor, trim(calibration.x.valueMin)),
            (.xEnd, "②", Self.xAxisColor, trim(calibration.x.valueMax)),
            (.yStart, "③", Self.yAxisColor, trim(calibration.y.valueMin)),
            (.yEnd, "④", Self.yAxisColor, trim(calibration.y.valueMax)),
        ]
        for (handle, name, color, value) in entries {
            let pixel = handlePosition(handle, calibration)
            let v = transform.viewPoint(fromImage: pixel)
            let side: CGFloat = 7

            let box = NSRect(x: v.x - side, y: v.y - side, width: side * 2, height: side * 2)
            color.setFill()
            NSBezierPath(ovalIn: box).fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(ovalIn: box)
            border.lineWidth = 2
            border.stroke()

            let text = Self.handleLabel(step: name, value: value)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attributes)
            let background = NSRect(x: v.x + side + 3, y: v.y - size.height / 2 - 2,
                                    width: size.width + 8, height: size.height + 4)
            color.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: background, xRadius: 3, yRadius: 3).fill()
            text.draw(at: NSPoint(x: background.minX + 4, y: background.minY + 2),
                      withAttributes: attributes)
        }
    }

    private func labelTick(_ text: String, at point: CGPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y),
                  withAttributes: attributes)
    }

    private func trim(_ v: Double) -> String {
        abs(v) >= 1e5 || (v != 0 && abs(v) < 1e-3)
            ? String(format: "%.2e", v)
            : String(format: "%g", v)
    }

    private func drawCurves() {
        // The active curve is drawn last so it is never buried under another one.
        let visible = state.lines.filter { $0.isVisible && !$0.points.isEmpty }
        for line in visible.sorted(by: { lhs, rhs in
            (lhs.id == state.activeLineID ? 1 : 0) < (rhs.id == state.activeLineID ? 1 : 0)
        }) {
            drawCurve(line)
        }
    }

    /// One curve: the polyline its point order defines, then the markers.
    ///
    /// Markers get a light halo ring because a point sitting on a curve of its
    /// own colour is otherwise invisible — the two merge into one blob. The ring
    /// also carries the sequence number where there is room, so the order that
    /// the polyline follows is readable rather than implied.
    private func drawCurve(_ line: CurveLine) {
        let isActive = line.id == state.activeLineID
        let (ordered, sweptCount) = line.orderedPointsAndSweptCount
        let view = ordered.map { transform.viewPoint(fromImage: $0) }
        guard !view.isEmpty else { return }

        let color = NSColor(srgbRed: CGFloat(line.color.r) / 255,
                            green: CGFloat(line.color.g) / 255,
                            blue: CGFloat(line.color.b) / 255,
                            alpha: 1)

        // While 点重排 is running the curve is drawn in two parts: the run the
        // brush has already numbered, and the points it has not reached yet. The
        // polyline's tail already jumps about the chart — that is what the tool is
        // for — but seeing *which* markers are still outstanding is the only way
        // to know how much sweeping is left, so the pending ones are drawn faint.
        let showsProgress = tool == .reorder && isActive
            && sweptCount > 0 && sweptCount < view.count
        let width: CGFloat = isActive ? 1.7 : 1.0
        let lineAlpha: CGFloat = isActive ? 0.9 : 0.35

        // The connecting polyline. This is what point order actually controls, so
        // drawing it is the only way the setting is visible on screen.
        func stroke(_ run: ArraySlice<CGPoint>, alpha: CGFloat) {
            guard run.count >= 2 else { return }
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            color.withAlphaComponent(alpha).setStroke()
            path.move(to: run.first!)
            for v in run.dropFirst() { path.line(to: v) }
            path.stroke()
        }
        if showsProgress {
            stroke(view[0..<sweptCount], alpha: lineAlpha)
            // One point of overlap, so the faint tail is joined to the rebuilt
            // run instead of starting a gap away from it.
            stroke(view[(sweptCount - 1)...], alpha: 0.22)
        } else {
            stroke(view[0...], alpha: lineAlpha)
        }

        let radius: CGFloat = isActive ? 3.6 : 2.6
        let halo = radius + 1.8

        // Batched by opacity: a run of markers is one fill, so splitting them
        // into numbered and pending costs a second fill rather than one per point.
        let batches = showsProgress ? [0..<sweptCount, sweptCount..<view.count] : [0..<view.count]
        for batch in batches {
            let isPending = showsProgress && batch.lowerBound >= sweptCount
            let haloPath = NSBezierPath()
            let discPath = NSBezierPath()
            for index in batch {
                let v = view[index]
                haloPath.appendOval(in: NSRect(x: v.x - halo, y: v.y - halo,
                                               width: halo * 2, height: halo * 2))
                discPath.appendOval(in: NSRect(x: v.x - radius, y: v.y - radius,
                                               width: radius * 2, height: radius * 2))
            }
            NSColor.white.withAlphaComponent(isPending ? 0.3 : (isActive ? 0.95 : 0.6)).setFill()
            haloPath.fill()
            color.withAlphaComponent(isPending ? 0.22 : (isActive ? 1.0 : 0.5)).setFill()
            discPath.fill()
        }

        // Start and end, so the direction of travel is obvious at a glance. While
        // a sweep is running the run that defines the curve is the numbered one,
        // so the end ring belongs at the end of that rather than on the last of
        // the stragglers.
        let endIndex = showsProgress ? sweptCount - 1 : view.count - 1
        drawEndpoint(view[0], color: color, radius: radius, isStart: true)
        if endIndex > 0 { drawEndpoint(view[endIndex], color: color, radius: radius, isStart: false) }

        guard isActive else { return }
        // Numbered only up to the brush, when there is a brush to report: the
        // labels are the confirmation that the points were renumbered, and an
        // unnumbered tail is precisely the part that has not been.
        drawSequenceNumbers(showsProgress ? Array(view[0..<sweptCount]) : view, color: color)
    }

    /// A ringed marker for the first and last point of a curve.
    private func drawEndpoint(_ v: CGPoint, color: NSColor, radius: CGFloat, isStart: Bool) {
        let r = radius + 2.6
        let box = NSRect(x: v.x - r, y: v.y - r, width: r * 2, height: r * 2)
        let ring = NSBezierPath(ovalIn: box)
        ring.lineWidth = 2
        (isStart ? NSColor.white : color).setStroke()
        ring.stroke()
        NSColor.black.withAlphaComponent(0.5).setStroke()
        let outline = NSBezierPath(ovalIn: box.insetBy(dx: -1, dy: -1))
        outline.lineWidth = 1
        outline.stroke()
    }

    /// Numbers a sample of the points, thinned so the labels never merge.
    ///
    /// Every point is numbered when they are far enough apart; otherwise the
    /// stride is widened to keep roughly 40 labels on screen, and the last point
    /// is always labelled so the total is readable.
    private func drawSequenceNumbers(_ view: [CGPoint], color: NSColor) {
        guard view.count >= 2, view.count <= 5_000 else { return }

        // Median gap between neighbours decides how many labels actually fit.
        var gaps: [CGFloat] = []
        gaps.reserveCapacity(view.count - 1)
        for (a, b) in zip(view, view.dropFirst()) {
            gaps.append(hypot(b.x - a.x, b.y - a.y))
        }
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        let stride = max(1, Int((14.0 / max(median, 0.5)).rounded(.up)))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]

        for index in Swift.stride(from: 0, to: view.count, by: stride) {
            let isLast = index == view.count - 1
            if !isLast && index % (stride * 2) != 0 && view.count > 60 { continue }
            let v = view[index]
            let text = "\(index + 1)"
            let size = text.size(withAttributes: attributes)
            let origin = NSPoint(x: v.x + 5, y: v.y - size.height - 2)
            let background = NSRect(x: origin.x - 2, y: origin.y - 1,
                                    width: size.width + 4, height: size.height + 2)
            color.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: background, xRadius: 2.5, yRadius: 2.5).fill()
            text.draw(at: origin, withAttributes: attributes)
        }
    }

    /// Pending calibration anchors, drawn as numbered markers with a label so
    /// the click being asked for is unambiguous.
    private func drawPendingScalePoints() {
        guard !pendingScalePoints.isEmpty else { return }
        let labels = CalibrationAnchors.clickOrder.enumerated()
            .map { "\(Self.circled($0.offset + 1)) \($0.element)" }
        let colors: [NSColor] = [Self.xAxisColor, Self.xAxisColor,
                                 Self.yAxisColor, Self.yAxisColor]

        // Connect the anchors placed so far so the axis being traced is visible
        // while clicking, not only afterwards. Two clicks make the X rule, four
        // make the Y rule — the same pairs the finished overlay will draw.
        func connect(_ a: Int, _ b: Int, _ color: NSColor) {
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.setLineDash([5, 4], count: 2, phase: 0)
            color.withAlphaComponent(0.8).setStroke()
            path.move(to: transform.viewPoint(fromImage: pendingScalePoints[a]))
            path.line(to: transform.viewPoint(fromImage: pendingScalePoints[b]))
            path.stroke()
        }
        if pendingScalePoints.count >= 2 { connect(0, 1, Self.xAxisColor) }
        if pendingScalePoints.count >= 4 { connect(2, 3, Self.yAxisColor) }

        for (index, pixel) in pendingScalePoints.enumerated() {
            let v = transform.viewPoint(fromImage: pixel)
            let r: CGFloat = 8
            let color = colors[min(index, colors.count - 1)]
            let dot = NSBezierPath(ovalIn: NSRect(x: v.x - r, y: v.y - r,
                                                  width: r * 2, height: r * 2))
            color.setFill()
            dot.fill()
            NSColor.white.setStroke()
            dot.lineWidth = 2
            dot.stroke()

            let text = labels[min(index, labels.count - 1)]
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attributes)
            let background = NSRect(x: v.x + r + 3, y: v.y - size.height / 2 - 2,
                                    width: size.width + 8, height: size.height + 4)
            color.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: background, xRadius: 3, yRadius: 3).fill()
            text.draw(at: NSPoint(x: background.minX + 4, y: background.minY + 2),
                      withAttributes: attributes)
        }
    }

    /// ①…④ for the anchor prompts.
    private static func circled(_ n: Int) -> String {
        ["①", "②", "③", "④"][max(0, min(3, n - 1))]
    }

    private func drawDragRect() {
        guard let rect = dragRect else { return }
        let a = transform.viewPoint(fromImage: PixelPoint(x: Double(rect.minX), y: Double(rect.minY)))
        let b = transform.viewPoint(fromImage: PixelPoint(x: Double(rect.maxX), y: Double(rect.maxY)))
        let viewRect = NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                              width: abs(b.x - a.x), height: abs(b.y - a.y))
        // 重新选点 wears a warning colour: the same gesture that adds points with
        // 区域取点 takes them away here, and the two must not look interchangeable.
        // Nothing is destroyed until the mouse comes up, so this is the whole
        // warning the gesture gets.
        let tint: NSColor = tool == .redigitize ? .systemOrange : .controlAccentColor
        tint.withAlphaComponent(0.15).setFill()
        viewRect.fill()
        tint.setStroke()
        let border = NSBezierPath(rect: viewRect)
        border.lineWidth = tool == .redigitize ? 1.5 : 1
        if tool == .redigitize { border.setLineDash([5, 3], count: 2, phase: 0) }
        border.stroke()
    }

    /// The ring under the pointer, shared by the eraser and 点重排.
    ///
    /// This is the whole feature for the eraser: the radius used to be invisible,
    /// so the only way to learn how much a dab would take was to dab and look. It
    /// carries the same 2pt white halo the data markers do, so it stays legible
    /// over a dark curve and over the white background alike.
    ///
    /// 点重排 draws the same ring in a different colour. The two gestures are
    /// identical — a circle dragged across the points — and one of them deletes,
    /// so telling them apart at a glance is not decoration.
    private func drawToolRing() {
        guard tool.usesRing, let p = hoverPoint, isInsideImage(p) else { return }
        let radius: CGFloat = tool == .reorder ? reorderRadius : eraserRadius
        let tint: NSColor = tool == .reorder ? .systemOrange : .systemRed
        let center = transform.viewPoint(fromImage: p)
        let rect = NSRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        let ring = NSBezierPath(ovalIn: rect)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        ring.lineWidth = 4
        ring.stroke()
        tint.setStroke()
        ring.lineWidth = 1.5
        ring.stroke()
        // A centre dot, so a small ring is still findable when the pointer image
        // (the disappearing-item cursor) is hidden over the image.
        let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
        tint.setFill()
        dot.fill()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let imagePoint = transform.imagePoint(fromView: viewPoint)

        // One snapshot per stroke, taken before anything can change. Everything
        // this press and the drags that follow do happens between here and the
        // release, so the whole gesture records as a single step — see
        // `endGesture`.
        beginGesture()

        switch tool {
        case .browse:
            // Grabbing a calibration handle beats panning, so an existing
            // calibration stays adjustable without a separate tool.
            if let handle = handle(at: viewPoint) {
                activeHandle = handle
            } else {
                isPanning = true
                lastPanPoint = viewPoint
            }

        case .setScale:
            guard isInsideImage(imagePoint) else { return }
            pendingScalePoints.append(imagePoint)
            needsDisplay = true
            // Every click that still has a next anchor to ask for is announced,
            // because the step prompt is read straight off
            // `pendingScalePoints.count`. Without this the strip kept naming the
            // first anchor while the user was placing the third and fourth: the
            // ①②③ markers on the chart are drawn from the same array and did
            // advance, so a stale prompt there reads as a *wrong* instruction
            // rather than a stale one — the worst way for it to fail.
            //
            // The fourth click is left out deliberately. It is answered by the
            // sheet, so re-announcing would only repaint the strip on the way
            // into a modal; the prompt already says 4/4 from the third click,
            // which is the anchor that click is placing.
            if pendingScalePoints.count < CalibrationAnchors.clickOrder.count {
                delegate?.canvasDidChangeState(self)
            } else if let anchors = CalibrationAnchors(ordered: pendingScalePoints) {
                delegate?.canvas(self, didCollectScalePoints: anchors)
            }

        case .pickLineColor:
            guard let color = sample(from: imagePoint) else { return }
            let id = ensureActiveLine()
            state.setLineColor(color, for: id)
            // Re-sampling the background alongside the curve keeps a hand-picked
            // background valid after the user re-picks a curve's colour.
            if state.lines.first(where: { $0.id == id })?.backgroundColor == nil,
               let detected = buffer.flatMap({ BackgroundDetector.detect(in: $0) }) {
                state.setBackgroundColor(detected, for: id)
            }
            rebuildMask(for: id)
            delegate?.canvasDidChangeState(self)

        case .pickBackgroundColor:
            guard let color = sample(from: imagePoint) else { return }
            let id = ensureActiveLine()
            state.setBackgroundColor(color, for: id)
            rebuildMask(for: id)
            delegate?.canvasDidChangeState(self)

        case .gridDigitize:
            guard isInsideImage(imagePoint) else { return }
            dragRect = CGRect(x: imagePoint.x, y: imagePoint.y, width: 0, height: 0)
            needsDisplay = true

        case .traceDigitize:
            runTrace(from: imagePoint)

        case .capture:
            append(points: [imagePoint])

        case .eraser:
            // The ring follows the press as well as the drag, so what is about to
            // be erased is visible before the button comes up.
            hoverPoint = imagePoint
            erase(at: imagePoint)

        case .redigitize:
            guard isInsideImage(imagePoint) else { return }
            hoverPoint = imagePoint
            dragRect = CGRect(x: imagePoint.x, y: imagePoint.y, width: 0, height: 0)
            needsDisplay = true

        case .reorder:
            guard isInsideImage(imagePoint) else { return }
            hoverPoint = imagePoint
            beginReorderStroke(at: imagePoint)
        }
    }

    /// Keeps the eraser ring under the pointer, and in 浏览 wakes the calibration
    /// handles when the pointer comes near one.
    ///
    /// Redrawing the whole canvas per pixel of travel is not free, which is what
    /// `tracksPointer` exists to avoid. 浏览 has nothing else to move, so there the
    /// redraw happens on the crossing only — the pointer position is recorded
    /// every event, cheap, and the frame is rebuilt only when it flips whether the
    /// handles are showing. An approach therefore costs two redraws, not one per
    /// event.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // `inVisibleRect` keeps the area sized to the view without this having to
        // know the bounds, so the rect passed here is only a placeholder.
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let imagePoint = transform.imagePoint(fromView: convert(event.locationInWindow, from: nil))
        guard imagePoint != hoverPoint else { return }
        guard tool.tracksPointer else {
            // 浏览 and the other tools that paint nothing under the pointer: the
            // only thing here that depends on where the pointer is, is whether the
            // calibration handles have woken up. Record the position, and repaint
            // only if that answer changed.
            let wasShowing = showsCalibrationHandles
            hoverPoint = imagePoint
            if showsCalibrationHandles != wasShowing { needsDisplay = true }
            return
        }
        hoverPoint = imagePoint
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoverPoint != nil else { return }
        hoverPoint = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)

        switch tool {
        case .browse:
            if let handle = activeHandle {
                dragHandle(handle, to: transform.imagePoint(fromView: viewPoint))
            } else if isPanning, let last = lastPanPoint {
                transform.pan(by: CGPoint(x: viewPoint.x - last.x, y: viewPoint.y - last.y))
                lastPanPoint = viewPoint
                needsDisplay = true
            }

        case .gridDigitize, .redigitize:
            if var rect = dragRect {
                let p = transform.imagePoint(fromView: viewPoint)
                rect.size = CGSize(width: p.x - rect.origin.x, height: p.y - rect.origin.y)
                dragRect = rect
                needsDisplay = true
            }

        case .eraser:
            hoverPoint = transform.imagePoint(fromView: viewPoint)
            erase(at: transform.imagePoint(fromView: viewPoint))
            needsDisplay = true

        case .reorder:
            let p = transform.imagePoint(fromView: viewPoint)
            hoverPoint = p
            extendReorderStroke(to: p)

        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch tool {
        case .browse:
            activeHandle = nil
            isPanning = false
            lastPanPoint = nil

        case .gridDigitize:
            defer { dragRect = nil; needsDisplay = true }
            guard let rect = dragRect else { return }
            let normalized = rect.standardized
            guard normalized.width >= 2, normalized.height >= 2 else {
                delegate?.canvas(self, didFailWith: "框选区域太小。请拖出一个覆盖曲线的矩形。")
                return
            }
            runGridDigitize(in: normalized)

        case .redigitize:
            defer { dragRect = nil; needsDisplay = true }
            guard let rect = dragRect else { return }
            let normalized = rect.standardized
            if normalized.width < 2 || normalized.height < 2 {
                // A click, not a drag: take the single nearest point. A mis-click
                // should not need a drag to undo, and a rectangle of no width
                // would otherwise report "no points in the region".
                redigitize(clickAt: PixelPoint(x: Double(normalized.midX),
                                               y: Double(normalized.midY)))
            } else {
                redigitize(in: normalized)
            }

        case .reorder:
            // The stroke ends; the sweep does not. The numbering is already in
            // the model, so the next press carries on from it and the user can
            // work over a long curve in as many passes as they need.
            reorderLastCentre = nil

        default:
            break
        }

        // After the switch, so a stroke that finished inside it — 区域取点 runs
        // its scan here, 重新选点 takes its rectangle here — is inside the one
        // step it belongs to rather than one step behind it. The tools whose work
        // happened on the press (自动跟踪, 手工取点, 取色) land here too: their
        // snapshot was taken before any of it.
        //
        // A press that changed nothing records nothing: a pan, a click on empty
        // space, the first three 标定 anchors, which live outside `ProjectState`.
        endGesture(tool.undoActionName)
    }

    override func scrollWheel(with event: NSEvent) {
        // Trackpad two-finger scroll pans; a mouse wheel zooms, matching the
        // habit most digitising tools train.
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            transform.pan(by: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
        } else {
            let factor = exp(Double(event.scrollingDeltaY) * 0.01)
            transform.zoom(by: factor, around: convert(event.locationInWindow, from: nil))
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        transform.zoom(by: 1 + Double(event.magnification),
                       around: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch tool {
        case .browse:    cursor = .openHand
        case .eraser:    cursor = .disappearingItem
        case .redigitize: cursor = .crosshair
        case .setScale, .capture, .pickLineColor, .pickBackgroundColor:
            cursor = .crosshair
        case .gridDigitize, .traceDigitize:
            cursor = .crosshair
        case .reorder:
            // Shared with the point-taking tools on purpose. The ring is what
            // tells the two drags apart — it is drawn in orange, the eraser's in
            // red — and there is no standard cursor that means "renumber".
            cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    /// `[` and `]` size the eraser, and `r` arms 重新选点, matching the menu's
    /// shortcuts. Handled here rather than in the menu because they have to work
    /// while the pointer is over the canvas, which is where the eraser is used.
    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }
        switch key {
        case "[": changeEraserRadius(by: -Self.eraserRadiusStep)
        case "]": changeEraserRadius(by: Self.eraserRadiusStep)
        default:  super.keyDown(with: event)
        }
    }

    // MARK: - Tool implementations

    private func isInsideImage(_ p: PixelPoint) -> Bool {
        guard let buffer else { return false }
        return p.x >= 0 && p.y >= 0 && p.x < Double(buffer.width) && p.y < Double(buffer.height)
    }

    private func sample(from p: PixelPoint) -> RGB8? {
        guard let buffer, isInsideImage(p) else { return nil }
        return buffer.color(atX: Int(p.x), y: Int(p.y))
    }

    private func append(points: [PixelPoint]) {
        guard !points.isEmpty else { return }
        ensureActiveLine()
        state.append(points: points, usingDefaultColor: nextColor())
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
    }

    private func nextColor() -> RGB8 {
        Self.palette[state.lines.count % Self.palette.count]
    }

    private func runGridDigitize(in rect: CGRect) {
        guard let mask = activeMask else {
            delegate?.canvas(self, didFailWith: "当前曲线还没有取色。请先用「取曲线颜色」点一下该曲线。")
            return
        }
        let pixelRect = PixelRect(x0: Int(rect.minX.rounded()),
                                  y0: Int(rect.minY.rounded()),
                                  x1: Int(rect.maxX.rounded()),
                                  y1: Int(rect.maxY.rounded()))
        let points = AreaDigitizer.digitize(mask: mask, rect: pixelRect,
                                            dx: max(1, state.gridSpacing))
        guard !points.isEmpty else {
            delegate?.canvas(self, didFailWith: "该区域内没有找到曲线像素。请检查取色是否准确,或调大颜色容差。")
            return
        }
        append(points: points)
    }

    private func runTrace(from seed: PixelPoint) {
        guard let mask = activeMask else {
            delegate?.canvas(self, didFailWith: "当前曲线还没有取色。请先用「取曲线颜色」点一下该曲线。")
            return
        }
        do {
            let result = try TraceDigitizer.trace(mask: mask, from: seed)
            // Thinned to the spacing the strip is showing. Thinning after the
            // walk, not during it, so the knob changes the sampling and not the
            // route — see `TraceDigitizer.decimate`.
            append(points: TraceDigitizer.decimate(result.points,
                                                   minSpacing: Double(state.traceSpacing)))
            if let branch = result.branchPoint {
                delegate?.canvas(self, didFailWith:
                    "在接近 (x: \(Int(branch.x)), y: \(Int(branch.y))) 处检测到分叉,跟踪已停止。"
                    + "这是原版的行为:请从分叉点继续跟踪,或改用「区域取点」。")
            }
        } catch {
            delegate?.canvas(self, didFailWith: "起点不在曲线上,请点得更准一些。")
        }
    }

    /// Deletes every point of the active curve inside the eraser's circle.
    ///
    /// The circle is the one drawn under the pointer, converted to image space —
    /// what the ring covers is what goes, which is the whole point of showing it.
    /// Returns how many points went, so the caller can report it.
    ///
    /// Goes through `ProjectState` rather than straight into `points`. Deleting a
    /// point renumbers every one after it, so a 点重排 sequence has to be dropped
    /// in the same step; doing the two by hand at each call site is exactly how
    /// that pairing gets forgotten.
    @discardableResult
    func erase(at p: PixelPoint) -> Int {
        guard let id = state.activeLineID else { return 0 }
        let radius = ringImageRadius
        let removed = state.removePoints(of: id) { point in
            (point.x - p.x) * (point.x - p.x) + (point.y - p.y) * (point.y - p.y) <= radius * radius
        }
        if removed > 0 {
            needsDisplay = true
            delegate?.canvasDidChangeState(self)
        }
        return removed
    }

    /// Removes the points inside `rect` and re-digitises that stretch.
    ///
    /// Two details make re-digitising safe rather than destructive. The region is
    /// grown by `pointTolerance` before anything is matched, so the points the
    /// user was aiming at are the points that go — a strict test against the
    /// rectangle they drew leaves stragglers behind every time. And the new points
    /// are merged by x rather than appended: the curve's own order setting may
    /// re-sort them later, but between the two the list is a sequence, and a
    /// sequence with the re-taken stretch tacked on the end draws a polyline that
    /// jumps across the whole chart and back.
    private func redigitize(in rect: CGRect) {
        guard let id = state.activeLineID,
              let index = state.lines.firstIndex(where: { $0.id == id }) else {
            delegate?.canvas(self, didFailWith: "没有可重新选点的曲线。")
            return
        }
        guard state.lines[index].isReadyForExtraction, let mask = activeMask else {
            delegate?.canvas(self, didFailWith: "「\(state.lines[index].name)」还没有取色。"
                + "请先用「取色」点一下这条曲线。")
            return
        }

        let region = NSRect(x: rect.minX - Self.pointTolerance,
                            y: rect.minY - Self.pointTolerance,
                            width: rect.width + Self.pointTolerance * 2,
                            height: rect.height + Self.pointTolerance * 2)
        let removed = state.removePoints(of: id) { region.contains(NSPoint(x: $0.x, y: $0.y)) }

        let pixelRect = PixelRect(x0: Int(rect.minX.rounded()),
                                  y0: Int(rect.minY.rounded()),
                                  x1: Int(rect.maxX.rounded()),
                                  y1: Int(rect.maxY.rounded()))
        let fresh = AreaDigitizer.digitize(mask: mask, rect: pixelRect,
                                           dx: max(1, state.gridSpacing))
        // Written back through `replacePoints` so the sweep is invalidated even in
        // the case the removal above did not touch anything but the refill adds to
        // the curve.
        var merged = state.lines[index].points
        merged.append(contentsOf: fresh)
        merged.sort { $0.x < $1.x }
        state.replacePoints(of: id, with: merged)

        needsDisplay = true
        delegate?.canvasDidChangeState(self)
        delegate?.canvas(self, didRedigitize: state.lines[index].name,
                         removed: removed, added: fresh.count)
    }

    /// The click-sized case: delete the single nearest point, if one is within
    /// reach. A mis-click should not need a drag to undo.
    private func redigitize(clickAt p: PixelPoint) {
        guard let id = state.activeLineID,
              let index = state.lines.firstIndex(where: { $0.id == id }),
              !state.lines[index].points.isEmpty else {
            delegate?.canvas(self, didFailWith: "没有可删除的数据点。")
            return
        }
        let nearest = state.lines[index].points.enumerated().min { lhs, rhs in
            Self.distance(lhs.element, p) < Self.distance(rhs.element, p)
        }
        guard let nearest, Self.distance(nearest.element, p) <= Self.pointTolerance * 2 else {
            delegate?.canvas(self, didFailWith: "附近没有数据点。拖出一个框可以重取一整段。")
            return
        }
        state.removePoint(of: id, at: nearest.offset)
        needsDisplay = true
        delegate?.canvasDidChangeState(self)
        delegate?.canvas(self, didRedigitize: state.lines[index].name, removed: 1, added: 0)
    }

    private static func distance(_ a: PixelPoint, _ b: PixelPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    /// How far outside the drawn rectangle a point may sit and still count as
    /// inside it, in image pixels. Generous on purpose: the user is aiming at
    /// markers drawn 3–18pt wide, so a strict hit test would leave stragglers
    /// behind every time.
    ///
    /// Not `private`: the selftest reproduces the matching rule to prove the
    /// points that go are the ones the rectangle touched, and a copy of the
    /// number there would drift from this one.
    static let pointTolerance: CGFloat = 6

    // MARK: - Bitmap conversion

    /// Decodes a CGImage into the packed-RGB buffer the digitizers consume.
    ///
    /// CGBitmapContext only supports 32 bits per pixel — a 24-bit one comes
    /// back nil — so the image is drawn into RGBA first and narrowed afterwards.
    static func makeBuffer(from cgImage: CGImage) -> BitmapBuffer? {
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let pixelCount = width * height
        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
        let drew: Bool = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        var pixels = [UInt8](repeating: 0, count: pixelCount * 3)
        for i in 0..<pixelCount {
            pixels[i * 3] = rgba[i * 4]
            pixels[i * 3 + 1] = rgba[i * 4 + 1]
            pixels[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return BitmapBuffer(width: width, height: height, pixels: pixels)
    }
}
