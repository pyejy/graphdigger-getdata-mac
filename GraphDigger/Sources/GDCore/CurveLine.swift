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

    /// Which coordinate system this curve's pixels are measured in — FR-13.
    ///
    /// **Optional only so that a project written before coordinate systems
    /// existed still opens.** A format-v1 file has one `calibration` for the
    /// whole project and curves that never had to say whose it was;
    /// `ProjectState.init(from:)` fills this in from that single system, so from
    /// the first load onward it is always set.
    ///
    /// Set at birth from the project's active system rather than left nil and
    /// resolved later, because "which system is this curve in" is exactly the
    /// question a wrong answer to which is invisible: on a three-subplot figure
    /// the ranges differ by orders of magnitude, so converting with the
    /// neighbour's mapping produces numbers that look perfectly plausible.
    public var calibrationID: UUID?

    public init(id: UUID = UUID(),
                name: String,
                color: RGB8,
                points: [PixelPoint] = [],
                isVisible: Bool = true,
                lineColor: RGB8? = nil,
                backgroundColor: RGB8? = nil,
                colorTolerance: Double = 60,
                order: PointOrder = .extraction,
                sweptOrder: [Int]? = nil,
                calibrationID: UUID? = nil) {
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
        self.calibrationID = calibrationID
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
        let (indices, sweptCount) = orderedPointIndicesAndSweptCount
        return (indices.map { points[$0] }, sweptCount)
    }

    /// The same thing again, as **indices into `points`**.
    ///
    /// What an editor needs, and the reason it exists rather than the points
    /// themselves: the marker drawn at display position *k* is stored at index
    /// `orderedPointIndices[k]`, and those are different numbers on any curve
    /// whose order is not 取点顺序 — sorted, reversed, or swept. Dragging by
    /// display position would move a different point from the one under the
    /// cursor, which is a bug that looks like the drag working.
    ///
    /// `orderedPointsAndSweptCount` is computed from this one, so the two cannot
    /// drift; a test asserts `points[indices]` equals the points it returns.
    public var orderedPointIndicesAndSweptCount: (indices: [Int], sweptCount: Int) {
        if order == .swept, let sweptOrder, !sweptOrder.isEmpty {
            return SweepReorder.resolveIndices(pointCount: points.count, sequence: sweptOrder)
        }
        return (order.applyIndices(to: points), points.count)
    }

    /// The display order, as stored indices.
    public var orderedPointIndices: [Int] { orderedPointIndicesAndSweptCount.indices }

    /// Where a point dropped into the segment between two displayed neighbours
    /// belongs in the stored sequence.
    ///
    /// `displayIndex` is the earlier end of the segment as drawn, so the answer
    /// is a stored position in `0...points.count`.
    ///
    /// The naive answer — "just after the point on the left" — is right only
    /// while the display order runs the same way as the stored array. On a
    /// reversed or swept curve the two displayed neighbours are stored at indices
    /// that run *downhill*, and inserting on the high side of the earlier one
    /// puts the new point at the opposite end of the polyline from the segment
    /// the user clicked. Picking the side that points toward the segment's other
    /// end is what makes the rule independent of which order is showing.
    ///
    /// Lives here rather than in the canvas because it is arithmetic on the
    /// order, not on the screen, and a unit test can pin every order mode.
    public func storedInsertionIndex(betweenDisplayIndex displayIndex: Int) -> Int? {
        let indices = orderedPointIndices
        guard displayIndex >= 0, displayIndex + 1 < indices.count else { return nil }
        let this = indices[displayIndex], next = indices[displayIndex + 1]
        return next > this ? this + 1 : this
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

/// Which of a point's two numbers is being written.
///
/// A named pair rather than a `Bool` or a leading `x:`/`y:` pair of methods,
/// because the two are symmetric: the sidebar's editable cells, the canvas'
/// drag, and anything that reads them back all treat the axes the same way, and
/// a signature that says `axis:` documents the symmetry where a `horizontal:`
/// flag would invite it being read as "the other one" somewhere.
public enum PointCoordinate: String, CaseIterable, Codable, Sendable {
    case x
    case y
}

/// One coordinate system: a pixel↔value mapping, the anchors it was traced from,
/// and a name to tell it from the others — FR-13.
///
/// A journal figure with `(a)(b)(c)` subplots has three of these on one image,
/// and nothing about the pixels says which curve belongs to which: the ranges
/// differ — 0–10 beside 0–100 — so a curve converted through the wrong one
/// yields numbers that look plausible and are wrong by an order of magnitude.
/// That is the whole reason each curve names its own system instead of the
/// project having one.
///
/// `calibration` is optional because a system exists from the moment the project
/// does. An image with no axes traced yet still needs somewhere for the first
/// calibration to land, and "declared, not yet calibrated" is a state the window
/// has to show rather than a missing object it has to guard against.
public struct CoordinateSystem: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var calibration: CalibrationMap?
    /// The four clicked anchors, kept for drawing the rules the user traced. The
    /// mapping itself lives in `calibration`.
    public var anchors: CalibrationAnchors?

    public init(id: UUID = UUID(),
                name: String,
                calibration: CalibrationMap? = nil,
                anchors: CalibrationAnchors? = nil) {
        self.id = id
        self.name = name
        self.calibration = calibration
        self.anchors = anchors
    }

    public var isCalibrated: Bool { calibration != nil }

    /// The anchors to draw, synthesised from the mapping when none were kept — a
    /// system whose calibration was built before anchors were stored, or edited
    /// into existence. Returns nil for an uncalibrated system, which has neither.
    public func displayAnchors() -> CalibrationAnchors? {
        anchors ?? calibration.map(CalibrationAnchors.init(fallbackFrom:))
    }
}

/// Everything about a digitising session except the image itself, which belongs
/// to the app layer.
public struct ProjectState: Equatable, Codable, Sendable {

    /// The coordinate systems of this project — FR-13.
    ///
    /// **Optional on purpose**, like every field added after the format shipped:
    /// the rule in `ProjectFile` is that a new field must be one the decoder can
    /// fill from a missing key, and only `Optional` qualifies. A project saved
    /// before this feature carries one `calibration` for the whole project
    /// instead, and `init(from:)` turns that into a single system — so nothing
    /// downstream ever has to ask which shape the file was.
    ///
    /// Read it through `systems`, which cannot be nil, or through `activeSystem`
    /// when what is wanted is the one being worked on.
    public var coordinateSystems: [CoordinateSystem]?

    /// Which system the tools act on: the one being calibrated, the one whose
    /// axes are drawn brightest, and the one new curves join.
    ///
    /// Optional for the same reason as above. An absent or stale id reads as the
    /// first system, so a single-system project never has to think about it and
    /// deleting the active system cannot leave the app pointing at nothing.
    public var activeCoordinateSystemID: UUID?

    /// 建遮膜时是否去掉图上的网格线 —— B-1。
    ///
    /// Optional, like every field added after the format shipped (`ProjectFile`
    /// 的规矩)。读的时候走 `removesGridLines`。
    ///
    /// 属于**工程**而不是视图状态:它改变的是"这条曲线取到哪些点"的前处理,
    /// 同一张图重开时要一模一样,所以它随 `.gdproj` 存、进撤销历史
    /// (与颜色容差同一类)。
    public var gridRemoval: Bool?

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

    /// Diameter of the symbols 符号匹配 looks for, in pixels — its one knob.
    ///
    /// Optional for the project-file compatibility rule, and read through
    /// `symbolDiameter`, which supplies the default. A third sampling setting
    /// sitting beside the other two, for the same reason: it describes how the
    /// user is reading the chart, not something about the curve, so running the
    /// matcher again with a different size replaces the points rather than
    /// leaving two readings to reconcile.
    public var markerDiameter: Int?

    /// The symbol diameter to match with, defaulted for a project written before
    /// the scatter matcher existed.
    ///
    /// The literal is duplicated in `CanvasView.markerDiameterDefault` — the two
    /// files cannot see each other — and a selftest asserts they agree, which is
    /// the only thing that stops them drifting.
    public var symbolDiameter: Int { markerDiameter ?? 11 }

    /// 建遮膜时是否去掉图上的网格线。缺省关 —— 它是有代价的一步(见
    /// `GridLineRemover`),而且只在真有网格的图上才有意义。
    public var removesGridLines: Bool { gridRemoval ?? false }

    public init(calibration: CalibrationMap? = nil,
                lines: [CurveLine] = [],
                activeLineID: UUID? = nil,
                defaultBackgroundColor: RGB8? = nil,
                defaultColorTolerance: Double = 60,
                gridSpacing: Int = 8,
                gridAxis: GridAxis? = nil,
                gridOffset: Int? = nil,
                traceSpacing: Int = 1,
                markerDiameter: Int? = nil,
                calibrationAnchors: CalibrationAnchors? = nil) {
        // A project always has at least one coordinate system, calibrated or not,
        // which is what makes "which system is this curve in" answerable from the
        // first curve onward. The id is `firstSystemID` rather than a fresh one so
        // that a state built here equals the one a format-v1 file migrates to.
        self.coordinateSystems = [CoordinateSystem(id: Self.firstSystemID,
                                                   name: Self.defaultSystemName,
                                                   calibration: calibration,
                                                   anchors: calibrationAnchors)]
        self.activeCoordinateSystemID = Self.firstSystemID
        self.lines = lines
        self.activeLineID = activeLineID
        self.defaultBackgroundColor = defaultBackgroundColor
        self.defaultColorTolerance = defaultColorTolerance
        self.gridSpacing = gridSpacing
        self.gridAxis = gridAxis
        self.gridOffset = gridOffset
        self.traceSpacing = traceSpacing
        self.markerDiameter = markerDiameter
    }

    // MARK: - Coordinate systems (FR-13)

    /// The id a project written before coordinate systems existed migrates to,
    /// and the one a fresh project's first system gets.
    ///
    /// A fixed value rather than a `UUID()` per load, so opening the same old
    /// file twice yields the same state. That is what lets the migration be
    /// asserted by comparing two states instead of by describing one, and it
    /// keeps `CurveLine.calibrationID` consistent with the system it names.
    /// Nothing ever merges two projects, so the sharing costs nothing.
    public static let firstSystemID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    public static let defaultSystemName = "坐标系 1"

    /// What a file written by this build contains.
    ///
    /// Spelled out rather than synthesised because the encoder and the decoder
    /// need **different** key sets: the v1 names below are read so that an old
    /// project still opens, but must never be written, or a file would carry two
    /// answers to "what is this project's calibration" and a reader would have to
    /// guess which one is current.
    private enum CodingKeys: String, CodingKey {
        case coordinateSystems, activeCoordinateSystemID
        case lines, activeLineID
        case defaultBackgroundColor, defaultColorTolerance, gridSpacing
        case gridAxis, gridOffset, traceSpacing, markerDiameter, gridRemoval
    }

    /// The names a **format-v1** file uses: one mapping for the whole project.
    /// Decode-only, and read from a second container so nothing here can leak
    /// into a file this build writes.
    private enum LegacyCodingKeys: String, CodingKey {
        case calibration, calibrationAnchors
    }

    /// Decodes both file shapes into one model.
    ///
    /// **Every field has to be listed here**, or it silently decodes as its
    /// default — which is the one hazard a hand-written decoder adds to a type
    /// whose fields are all optional for exactly this reason. The JSON round-trip
    /// test sets each field to a non-default value, so a forgotten one shows up
    /// as a state that does not equal itself.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lines = try container.decodeIfPresent([CurveLine].self, forKey: .lines) ?? []
        activeLineID = try container.decodeIfPresent(UUID.self, forKey: .activeLineID)
        defaultBackgroundColor = try container.decodeIfPresent(RGB8.self,
                                                               forKey: .defaultBackgroundColor)
        defaultColorTolerance = try container.decodeIfPresent(Double.self,
                                                              forKey: .defaultColorTolerance) ?? 60
        gridSpacing = try container.decodeIfPresent(Int.self, forKey: .gridSpacing) ?? 8
        gridAxis = try container.decodeIfPresent(GridAxis.self, forKey: .gridAxis)
        gridOffset = try container.decodeIfPresent(Int.self, forKey: .gridOffset)
        traceSpacing = try container.decodeIfPresent(Int.self, forKey: .traceSpacing) ?? 1
        markerDiameter = try container.decodeIfPresent(Int.self, forKey: .markerDiameter)
        gridRemoval = try container.decodeIfPresent(Bool.self, forKey: .gridRemoval)

        let systems = try container.decodeIfPresent([CoordinateSystem].self,
                                                    forKey: .coordinateSystems)
        if let systems, !systems.isEmpty {
            coordinateSystems = systems
            activeCoordinateSystemID = try container.decodeIfPresent(UUID.self,
                                                                     forKey: .activeCoordinateSystemID)
        } else {
            // Format v1: one mapping for the whole project, and curves that were
            // never asked which mapping they belonged to.
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            coordinateSystems = [CoordinateSystem(
                id: Self.firstSystemID,
                name: Self.defaultSystemName,
                calibration: try legacy.decodeIfPresent(CalibrationMap.self,
                                                        forKey: .calibration),
                anchors: try legacy.decodeIfPresent(CalibrationAnchors.self,
                                                    forKey: .calibrationAnchors))]
            activeCoordinateSystemID = Self.firstSystemID
            // Without this the curves would have no owner and a three-system
            // project could never be built by opening one — but more to the
            // point, leaving them all nil would make the first save from here
            // ambiguous about a project that was never ambiguous before.
            for index in lines.indices where lines[index].calibrationID == nil {
                lines[index].calibrationID = Self.firstSystemID
            }
        }

        // A stale or absent pointer reads as the first system, so a file whose
        // active system was deleted still opens onto something.
        let all = coordinateSystems ?? []
        if !all.contains(where: { $0.id == activeCoordinateSystemID }) {
            activeCoordinateSystemID = all.first?.id
        }
    }

    public var systems: [CoordinateSystem] { coordinateSystems ?? [] }

    /// The system the tools act on, or nil only for a file that names none.
    public var activeSystem: CoordinateSystem? {
        let all = systems
        guard !all.isEmpty else { return nil }
        if let match = all.first(where: { $0.id == activeCoordinateSystemID }) { return match }
        return all.first
    }

    public var activeSystemIndex: Int? {
        guard let id = activeSystem?.id else { return nil }
        return systems.firstIndex { $0.id == id }
    }

    public var activeCalibration: CalibrationMap? { activeSystem?.calibration }

    /// The active system's mapping — **for the screen, not for arithmetic**.
    ///
    /// The canvas draws the axes of the system being worked on, so this is what
    /// it wants, and for a single-system project it is the whole story. Anything
    /// that converts a *curve's* points — export, the data table, the data view —
    /// must ask `calibration(for:)` instead: on a multi-subplot image a curve two
    /// panels away has a completely different mapping, and converting it with
    /// this one produces numbers that look right and are wrong by orders of
    /// magnitude. Because selecting a curve also makes its system active, the two
    /// agree for the curve in hand — which is exactly why the mistake would go
    /// unnoticed.
    ///
    /// Settable, and the setter writes the **active** system. Get and set have to
    /// mean the same thing or a caller that reads-then-writes would silently
    /// retarget a different system; and every writer before FR-13 meant "the
    /// project's calibration", which with one system is the same thing.
    public var calibration: CalibrationMap? {
        get { activeCalibration }
        set {
            guard let index = activeSystemIndex else { return }
            coordinateSystems?[index].calibration = newValue
        }
    }

    /// The active system's anchors, for the draggable markers. Writes the active
    /// system, for the same reason as above; nil clears them.
    public var calibrationAnchors: CalibrationAnchors? {
        get { activeSystem?.anchors }
        set {
            guard let index = activeSystemIndex else { return }
            coordinateSystems?[index].anchors = newValue
        }
    }

    /// Whether **every** system has a mapping.
    ///
    /// What the status line reports. With three systems, "标定完成" while one is
    /// still uncalibrated would be a claim the next export contradicts — and the
    /// status line is the only place that claim is made.
    public var isFullyCalibrated: Bool {
        let all = systems
        return !all.isEmpty && all.allSatisfy(\.isCalibrated)
    }

    /// 1-based position of a system, for menus and the status line.
    public func ordinal(ofSystem id: UUID) -> Int? {
        systems.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// The mapping that converts a curve's pixels, or nil when it has none.
    ///
    /// Nil happens for a curve whose system was deleted out from under it — which
    /// `removeCoordinateSystem` refuses to do — and for a system declared but not
    /// yet calibrated. Both mean "these points have no numeric reading yet",
    /// which the exporters report as `calibrationMissing` rather than inventing
    /// one from a neighbouring panel.
    public func calibration(for line: CurveLine) -> CalibrationMap? {
        calibration(forSystem: line.calibrationID)
    }

    public func calibration(forSystem id: UUID?) -> CalibrationMap? {
        guard let id else { return nil }
        return systems.first { $0.id == id }?.calibration
    }

    /// The curves measured in a given system.
    public func curves(usingSystem id: UUID) -> [CurveLine] {
        lines.filter { $0.calibrationID == id }
    }

    // MARK: - Calibration

    /// Builds and installs a calibration from four clicked anchors: the X axis'
    /// start and end, then the Y axis'.
    ///
    /// Four points rather than three because the axes need not meet. The mapping
    /// itself is built by `CalibrationMap.init(anchors:)`, which takes each axis
    /// from its own pair — so a point clicked slightly off-axis still calibrates
    /// correctly, and direction follows whichever way the user drew the axis.
    ///
    /// Retargeted onto the **active** system by FR-13. The first calibration of a
    /// project lands on the system every new project starts with, so the
    /// single-system flow is unchanged from the user's side.
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
        guard let index = activeSystemIndex else {
            coordinateSystems = [CoordinateSystem(id: Self.firstSystemID,
                                                  name: Self.defaultSystemName,
                                                  calibration: map,
                                                  anchors: anchors)]
            activeCoordinateSystemID = Self.firstSystemID
            return map
        }
        coordinateSystems?[index].calibration = map
        coordinateSystems?[index].anchors = anchors
        return map
    }

    /// Replaces the active system's mapping while leaving the clicked anchors
    /// where they are.
    ///
    /// This is the edit-the-numbers path: the user is correcting a value, not
    /// re-tracing an axis, so the four markers must not move. Going through
    /// `applyCalibration` instead would rebuild the anchors from whatever pixels
    /// were passed and lose the ones on screen.
    public mutating func installCalibration(_ map: CalibrationMap) {
        guard let index = activeSystemIndex else { return }
        coordinateSystems?[index].calibration = map
    }

    /// Moves the active system's anchors without touching its mapping.
    ///
    /// The drag-a-handle path: the user is correcting where an axis was traced,
    /// so the four markers follow the pointer while the numbers stay put. Split
    /// from `installCalibration` so neither call site has to reach into
    /// `coordinateSystems` and index it by hand.
    public mutating func installAnchors(_ anchors: CalibrationAnchors) {
        guard let index = activeSystemIndex else { return }
        coordinateSystems?[index].anchors = anchors
    }

    /// Drops the active system's mapping and its display anchors, keeping
    /// extracted points — they are stored in pixel space and stay valid.
    ///
    /// The system itself stays: it may own curves, and deleting it here would
    /// silently strand them.
    public mutating func clearCalibration() {
        guard let index = activeSystemIndex else { return }
        coordinateSystems?[index].calibration = nil
        coordinateSystems?[index].anchors = nil
    }

    /// Replaces every system with one fresh, uncalibrated one — what loading a
    /// new image means.
    ///
    /// One system rather than none, for the same reason `init` makes one: the
    /// invariant "every curve has an owner" has to hold from the first curve.
    public mutating func resetCoordinateSystems() {
        coordinateSystems = [CoordinateSystem(id: Self.firstSystemID,
                                              name: Self.defaultSystemName)]
        activeCoordinateSystemID = Self.firstSystemID
    }

    /// Adds a system and makes it active. New curves join it; existing ones stay
    /// where they are until the user says otherwise.
    @discardableResult
    public mutating func addCoordinateSystem(name: String? = nil) -> UUID {
        let system = CoordinateSystem(name: name ?? "坐标系 \(systems.count + 1)")
        coordinateSystems = systems + [system]
        activeCoordinateSystemID = system.id
        return system.id
    }

    public mutating func setActiveCoordinateSystem(id: UUID) {
        guard systems.contains(where: { $0.id == id }) else { return }
        activeCoordinateSystemID = id
    }

    public mutating func renameCoordinateSystem(id: UUID, to name: String) {
        guard let index = systems.firstIndex(where: { $0.id == id }) else { return }
        coordinateSystems?[index].name = name
    }

    /// Moves a curve into a system.
    ///
    /// Returns false for an unknown curve or system, so a caller cannot leave a
    /// curve pointing at nothing.
    @discardableResult
    public mutating func assign(curveID: UUID, toSystem systemID: UUID) -> Bool {
        guard systems.contains(where: { $0.id == systemID }),
              let index = lines.firstIndex(where: { $0.id == curveID }) else { return false }
        lines[index].calibrationID = systemID
        return true
    }

    /// Removes a system, unless it is the last one or curves are still in it.
    ///
    /// **Both refusals are deliberate.** Deleting the last system would leave
    /// curves with no owner, and every conversion would have to invent one.
    /// Deleting one that owns curves would silently re-measure those curves in a
    /// different coordinate system — the exact failure this feature exists to
    /// prevent, and one that leaves no trace: the points do not move, only their
    /// meaning does. The caller asks `curves(usingSystem:)` first so it can say
    /// how many and which.
    @discardableResult
    public mutating func removeCoordinateSystem(id: UUID) -> Bool {
        guard systems.count > 1, systems.contains(where: { $0.id == id }),
              curves(usingSystem: id).isEmpty else { return false }
        coordinateSystems = systems.filter { $0.id != id }
        if activeCoordinateSystemID == id {
            activeCoordinateSystemID = coordinateSystems?.first?.id
        }
        return true
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
    /// usable once its own colour is sampled, and the **active** coordinate
    /// system — so a curve drawn while panel (b) is being worked on is measured
    /// in panel (b), without the user having to say so afterwards.
    @discardableResult
    public mutating func addLine(name: String? = nil, color: RGB8) -> UUID {
        let line = CurveLine(name: name ?? "曲线 \(lines.count + 1)",
                             color: color,
                             backgroundColor: defaultBackgroundColor,
                             colorTolerance: defaultColorTolerance,
                             calibrationID: activeSystem?.id)
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

    /// Moves one point to a new position in pixel space — FR-6.4.
    ///
    /// The index is into the **stored** sequence, not the displayed one; callers
    /// with a position on screen go through `CurveLine.orderedPointIndices`
    /// first. See the note there for why that conversion is not optional.
    ///
    /// **The sweep record survives this**, unlike an insert or a delete, and that
    /// is the whole reason this is a method of its own rather than a call to
    /// `replacePoints`. `sweptOrder` holds *indices*, and a move changes no
    /// index — the sequence still names the same points in the same order. To
    /// drop it anyway would mean a user who nudged one marker three pixels lost
    /// the ordering of a curve that took a minute of sweeping to get right, and
    /// would not find out until the polyline rearranged itself.
    ///
    /// Returns whether the point actually moved, so a press that ends without
    /// travel records no undo step.
    @discardableResult
    public mutating func movePoint(of id: UUID, at index: Int, to point: PixelPoint) -> Bool {
        guard let lineIndex = lines.firstIndex(where: { $0.id == id }),
              index >= 0, index < lines[lineIndex].points.count else { return false }
        guard lines[lineIndex].points[index] != point else { return false }
        lines[lineIndex].points[index] = point
        return true
    }

    /// Inserts a point into the stored sequence at `index` — FR-6.4.
    ///
    /// `index` is a stored position in `0...points.count`, and the caller is
    /// expected to have worked out which position puts the new point between the
    /// two markers the user clicked between *in the order being displayed*. That
    /// is not simply "after the one on the left": on a reversed or swept curve
    /// the neighbouring stored indices can run downhill, and inserting on the
    /// wrong side of one puts the new point at the far end of the polyline. The
    /// rule lives in the canvas, where the display order is known, and the tests
    /// assert the outcome — the new point's neighbours in display order are the
    /// segment's two ends.
    ///
    /// Unlike a move, this **drops the sweep**: the whole sequence is a list of
    /// indices and every one after the insertion point now means a different
    /// point, so keeping it would rearrange the curve according to a record that
    /// no longer describes it.
    @discardableResult
    public mutating func insertPoint(of id: UUID, at index: Int, point: PixelPoint) -> Bool {
        guard let lineIndex = lines.firstIndex(where: { $0.id == id }),
              index >= 0, index <= lines[lineIndex].points.count else { return false }
        lines[lineIndex].points.insert(point, at: index)
        invalidateSweep(at: lineIndex)
        return true
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
