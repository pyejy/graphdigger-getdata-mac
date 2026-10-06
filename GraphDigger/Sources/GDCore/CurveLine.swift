import Foundation

/// One extracted curve: its identity, display colour and the points taken from
/// the image.
///
/// Points are stored in **pixel** space, not data space. That is deliberate:
/// re-calibrating (correcting a reference value, flipping a log toggle) then
/// updates every extracted curve for free, instead of leaving stale numbers
/// baked in. Data-space values are computed on demand through `CalibrationMap`.
public struct CurveLine: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// Colour the points are drawn with. Defaults to the colour sampled from the
    /// image but can be changed, which matters when a chart uses several similar
    /// colours and the point layers would otherwise be hard to tell apart.
    public var color: RGB8
    /// Points in the order they were taken — the raw record.
    public var points: [PixelPoint]
    public var isVisible: Bool

    /// The curve colour sampled from the image for *this* line. Each curve has
    /// its own, which is what makes several differently coloured curves on one
    /// chart independently extractable.
    public var lineColor: RGB8?
    /// The background sampled for this line.
    public var backgroundColor: RGB8?
    /// Colour-distance tolerance used when building this line's mask.
    public var colorTolerance: Double

    /// How the points are ordered for display and export.
    public var order: PointOrder

    /// Indices into `points`, in the order the «点重排» ring brush numbered them.
    ///
    /// Nil or empty means the curve has never been swept. Stored beside `points`
    /// rather than reordering them in place for two reasons. A sweep is not a
    /// property of the points — it is the user's gesture, and two people sweeping
    /// the same curve can legitimately disagree — so it does not belong in the
    /// array that records what was extracted. Overwriting the extraction order
    /// would also make a sweep that goes wrong recoverable only by undoing the
    /// whole gesture, where this way switching back to «取点顺序» restores it —
    /// and does so without the sweep having to be the last thing that happened.
    ///
    /// **Indices, not points.** Anything that inserts or deletes a point
    /// invalidates the whole sequence, which is why every mutation in
    /// `ProjectState` clears it.
    public var sweptOrder: [Int]?

    public init(id: UUID = UUID(),
                name: String,
                color: RGB8,
                points: [PixelPoint] = [],
                isVisible: Bool = true,
                lineColor: RGB8? = nil,
                backgroundColor: RGB8? = nil,
                colorTolerance: Double = 60,
                order: PointOrder = .extraction,
                sweptOrder: [Int]? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.points = points
        self.isVisible = isVisible
        self.lineColor = lineColor
        self.backgroundColor = backgroundColor
        self.colorTolerance = colorTolerance
        self.order = order
        self.sweptOrder = sweptOrder
    }

    /// Points in their configured order. This is what gets drawn and exported —
    /// the polyline would be wrong otherwise.
    public var orderedPoints: [PixelPoint] {
        orderedPointsAndSweptCount.points
    }

    /// The display order, plus how many leading entries the ring brush produced.
    ///
    /// The count is what lets the canvas draw the points already numbered
    /// differently from the ones still waiting: they are exactly the first
    /// `sweptCount` of `orderedPoints`. When there is no sweep to show it equals
    /// the point count, so nothing is ever dimmed by accident.
    public var orderedPointsAndSweptCount: (points: [PixelPoint], sweptCount: Int) {
        if order == .swept, let sweptOrder, !sweptOrder.isEmpty {
            return SweepReorder.resolve(points, sequence: sweptOrder)
        }
        return (order.apply(to: points), points.count)
    }

    /// How many of this curve's points the ring brush has numbered.
    public var sweptPointCount: Int {
        guard order == .swept, let sweptOrder else { return 0 }
        return min(sweptOrder.count, points.count)
    }

    /// Whether a sweep is recorded and currently being shown.
    public var hasSweepToShow: Bool {
        order == .swept && !(sweptOrder ?? []).isEmpty
    }

    /// Points converted to chart values, in order.
    public func dataPoints(using calibration: CalibrationMap) throws -> [DataPoint] {
        try orderedPoints.map { try calibration.data(fromPixel: $0) }
    }

    /// Whether a line is ready to be used for extracting points.
    public var isReadyForExtraction: Bool { lineColor != nil }

    /// Diagnostic on the current order, for warning about a badly ordered line.
    public var orderDiagnosis: OrderDiagnosis { OrderDiagnosis(points: orderedPoints) }
}

/// Everything about a digitising session except the image itself, which belongs
/// to the app layer.
public struct ProjectState: Equatable, Codable, Sendable {
    public var calibration: CalibrationMap?
    public var lines: [CurveLine]
    public var activeLineID: UUID?

    /// The image's background colour, sampled once when the image loads. Every
    /// new curve starts from it, so extracting a curve needs a single click on
    /// that curve rather than one click on the curve and one on the background.
    public var defaultBackgroundColor: RGB8?
    /// Tolerance applied to newly created curves.
    public var defaultColorTolerance: Double
    /// Grid spacing for area digitising, in pixels.
    public var gridSpacing: Int

    /// Which way the area digitizer's scan lines run — FR-5.4.
    ///
    /// **Optional on purpose.** `ProjectFile`'s compatibility rule is that a
    /// field added to this type has to be one the synthesised decoder can fill
    /// from a missing key — true of `Optional` and of nothing else. A project
    /// saved before this option existed still has to open. Read it through
    /// `areaDigitizingGrid`, which supplies the default.
    public var gridAxis: GridAxis?

    /// Where the grid's scan lines fall, as an **absolute** pixel phase — FR-5.5.
    ///
    /// Optional for the same reason as `gridAxis`. The lines are the lattice
    /// `gridOffset + k·gridSpacing`; a shift of one whole spacing draws the same
    /// grid, so the digitizer folds it rather than storing it in whatever form it
    /// was handed.
    public var gridOffset: Int?

    /// Both grid options as the digitizer wants them, defaulted for project files
    /// written before either existed.
    ///
    /// One accessor rather than two resolved properties because a scan needs both
    /// a direction and a phase, and reading one without the other would be a
    /// half-applied setting.
    public var areaDigitizingGrid: (axis: GridAxis, phase: Int) {
        (gridAxis ?? .x, gridOffset ?? 0)
    }

    /// How far apart auto trace keeps its points, in pixels of travel along the
    /// path. 1 keeps every pixel the walk visited.
    ///
    /// Beside `gridSpacing` rather than on the curve, and for the same reason: it
    /// is a property of how the user is sampling, not of the samples. Re-tracing
    /// a curve with a different density therefore replaces points rather than
    /// leaving two sampling schemes to reconcile.
    public var traceSpacing: Int

    /// The four clicked anchors — X start, X end, Y start, Y end. Kept for
    /// drawing the axis rules the user actually traced; the mapping itself
    /// lives in `calibration`. The two axes may have different starts.
    public var calibrationAnchors: CalibrationAnchors?

    public init(calibration: CalibrationMap? = nil,
                lines: [CurveLine] = [],
                activeLineID: UUID? = nil,
                defaultBackgroundColor: RGB8? = nil,
                defaultColorTolerance: Double = 60,
                gridSpacing: Int = 8,
                gridAxis: GridAxis? = nil,
                gridOffset: Int? = nil,
                traceSpacing: Int = 1,
                calibrationAnchors: CalibrationAnchors? = nil) {
        self.calibration = calibration
        self.lines = lines
        self.activeLineID = activeLineID
        self.defaultBackgroundColor = defaultBackgroundColor
        self.defaultColorTolerance = defaultColorTolerance
        self.gridSpacing = gridSpacing
        self.gridAxis = gridAxis
        self.gridOffset = gridOffset
        self.traceSpacing = traceSpacing
        self.calibrationAnchors = calibrationAnchors
    }

    // MARK: - Calibration

    /// Builds and installs a calibration from four clicked anchors: the X axis'
    /// start and end, then the Y axis'.
    ///
    /// Four points rather than three because the axes need not meet. The mapping
    /// itself is built by `CalibrationMap.init(anchors:)`, which takes each axis
    /// from its own pair — so a point clicked slightly off-axis still calibrates
    /// correctly, and direction follows whichever way the user drew the axis.
    @discardableResult
    public mutating func applyCalibration(anchors: CalibrationAnchors,
                                          xStartValue: Double,
                                          xEndValue: Double,
                                          yStartValue: Double,
                                          yEndValue: Double,
                                          xIsLogarithmic: Bool,
                                          yIsLogarithmic: Bool) -> CalibrationMap {
        let map = CalibrationMap(anchors: anchors,
                                 xStartValue: xStartValue, xEndValue: xEndValue,
                                 yStartValue: yStartValue, yEndValue: yEndValue,
                                 xIsLogarithmic: xIsLogarithmic,
                                 yIsLogarithmic: yIsLogarithmic)
        calibration = map
        calibrationAnchors = anchors
        return map
    }

    /// Replaces the mapping while leaving the clicked anchors where they are.
    ///
    /// This is the edit-the-numbers path: the user is correcting a value, not
    /// re-tracing an axis, so the four markers must not move. Going through
    /// `applyCalibration` instead would rebuild the anchors from whatever pixels
    /// were passed and lose the ones on screen.
    public mutating func installCalibration(_ map: CalibrationMap) {
        calibration = map
    }

    /// Drops the calibration and its display anchors, keeping extracted points.
    public mutating func clearCalibration() {
        calibration = nil
        calibrationAnchors = nil
    }

    // MARK: - Lines

    public var activeLine: CurveLine? {
        guard let activeLineID else { return nil }
        return lines.first { $0.id == activeLineID }
    }

    public var activeLineIndex: Int? {
        guard let activeLineID else { return nil }
        return lines.firstIndex { $0.id == activeLineID }
    }

    /// Creates a curve. It inherits the image's background so it is immediately
    /// usable once its own colour is sampled.
    @discardableResult
    public mutating func addLine(name: String? = nil, color: RGB8) -> UUID {
        let line = CurveLine(name: name ?? "曲线 \(lines.count + 1)",
                             color: color,
                             backgroundColor: defaultBackgroundColor,
                             colorTolerance: defaultColorTolerance)
        lines.append(line)
        activeLineID = line.id
        return line.id
    }

    public mutating func removeLine(id: UUID) {
        lines.removeAll { $0.id == id }
        if activeLineID == id { activeLineID = lines.last?.id }
    }

    public mutating func rename(id: UUID, to name: String) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].name = name
    }

    /// Records the sampled curve colour on a line.
    ///
    /// The line's *display* colour follows the sampled one too: clicking a red
    /// curve should make that curve's markers red, which is how the user keeps
    /// track of which curve they are working on when a chart has several.
    public mutating func setLineColor(_ color: RGB8, for id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].lineColor = color
        lines[index].color = color
    }

    public mutating func setBackgroundColor(_ color: RGB8, for id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].backgroundColor = color
    }

    public mutating func setColorTolerance(_ tolerance: Double, for id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].colorTolerance = max(1, min(442, tolerance))
    }

    public mutating func setOrder(_ order: PointOrder, for id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].order = order
    }

    /// Appends to the active line, creating one if none exists yet.
    ///
    /// Points are appended to the stored sequence; the line's `order` decides how
    /// that sequence is presented, so appending can never corrupt the ordering a
    /// user already chose.
    public mutating func append(points: [PixelPoint], usingDefaultColor defaultColor: RGB8) {
        guard !points.isEmpty else { return }
        if activeLineID == nil || activeLine == nil {
            addLine(color: defaultColor)
        }
        guard let index = activeLineIndex else { return }
        lines[index].points.append(contentsOf: points)
        invalidateSweep(at: index)
    }

    public mutating func replacePoints(of id: UUID, with points: [PixelPoint]) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].points = points
        invalidateSweep(at: index)
    }

    /// Removes the points of a line that satisfy `shouldRemove`.
    ///
    /// Returns how many went, so the caller can report it. This exists so the
    /// eraser and 重新选点 do not reach into `points` directly: deleting a point
    /// renumbers every index after it, and the sweep record has to be dropped in
    /// the same breath or the next redraw would rearrange the curve according to
    /// indices that now mean something else.
    @discardableResult
    public mutating func removePoints(of id: UUID,
                                      where shouldRemove: (PixelPoint) -> Bool) -> Int {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return 0 }
        let before = lines[index].points.count
        lines[index].points.removeAll(where: shouldRemove)
        let removed = before - lines[index].points.count
        if removed > 0 { invalidateSweep(at: index) }
        return removed
    }

    /// Removes one point by position in the stored sequence.
    ///
    /// The single-point counterpart of `removePoints(of:where:)`, and here for the
    /// same reason: 重新选点's click-sized case aims at one marker, and going
    /// through the model is what keeps the sweep record in step with it.
    @discardableResult
    public mutating func removePoint(of id: UUID, at index: Int) -> PixelPoint? {
        guard let lineIndex = lines.firstIndex(where: { $0.id == id }),
              index >= 0, index < lines[lineIndex].points.count else { return nil }
        let removed = lines[lineIndex].points.remove(at: index)
        invalidateSweep(at: lineIndex)
        return removed
    }

    // MARK: - Sweep reorder

    /// Records the ring brush's progress and shows it.
    ///
    /// The curve switches to «重排顺序» here rather than the user having to pick
    /// it, because sweeping *is* the act of choosing that order — asking for a
    /// second decision before anything visibly changes would leave the gesture
    /// looking like it did nothing.
    public mutating func recordSweep(_ sequence: [Int], for id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].sweptOrder = sequence
        lines[index].order = .swept
    }

    /// Drops the sweep and returns the curve to its extraction order.
    public mutating func clearSweep(for id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        invalidateSweep(at: index)
    }

    /// Drops a sweep record, and the mode that presents it along with it.
    ///
    /// Leaving `order` on `.swept` with nothing to show would silently fall back
    /// to the extraction order through `PointOrder.apply` while the menu and the
    /// panel went on claiming 重排顺序 — the setting would be lying about what is
    /// on screen. Resetting it is also the honest report of what happened: the
    /// points changed, so the sweep no longer applies.
    private mutating func invalidateSweep(at index: Int) {
        lines[index].sweptOrder = nil
        if lines[index].order == .swept { lines[index].order = .extraction }
    }

    /// Total points across every curve.
    public var totalPointCount: Int {
        lines.reduce(0) { $0 + $1.points.count }
    }
}
