import Foundation

/// Rebuilds a curve's point order from the path of a ring brush.
///
/// Area digitising samples a chart column by column, so on any curve that is not
/// single-valued — a circle, a closed loop, a vertical run — the points come out
/// in an order no global sort can repair: `PointOrder` ranks by x, and a curve
/// that doubles back has several points to every column. The order that is
/// actually right is the one the person dragging the ring has in mind, which is
/// why reordering is a gesture here and not another entry in the order menu.
///
/// The whole difficulty is that mouse events are *sampled*, not continuous. At
/// speed two events can be a hundred pixels apart while the ring's radius is
/// eighteen, so numbering "the points inside the ring right now" both misses
/// whole stretches and gets the catch wrong. Two things fix that:
///
/// 1. **Resampling the path.** Each leg of the drag is walked in steps of half a
///    radius, so consecutive sample circles always overlap heavily and no point
///    can slip through the gap between two of them. This is the defence that
///    makes sweeping fast safe, and it is why the ring can be dragged in a
///    straight line across a wiggly curve and still take every point on it.
/// 2. **Ordering a catch by projection on the direction of travel.** Points
///    picked up in one sample are ranked by how far along the motion they lie,
///    not by distance from the ring's centre — the near ones are not the ones
///    the brush reached first.
///
/// A press with no movement has no direction to project onto, so it falls back
/// to distance from the centre. That is a limitation of the input rather than of
/// the algorithm: a click can fill a gap the brush skipped, but it cannot say
/// which of the points it touched came first.
public struct SweepReorder: Equatable, Sendable {

    /// Indices into the curve's `points`, in the order the brush numbered them.
    /// The first entry is the first point reached.
    public private(set) var sequence: [Int]

    /// How many points the curve had when this brush started. Fixed for the life
    /// of one sweep: inserting or deleting a point would renumber every index
    /// after it, so a change means the sequence has to be thrown away instead.
    /// `ProjectState` enforces that.
    public let pointCount: Int

    /// Indices already numbered, as a set, so a catch does not have to scan the
    /// sequence to find out whether a point has been taken.
    private var taken: Set<Int>

    /// A sample step of half a radius.
    ///
    /// Any step under one radius keeps consecutive circles overlapping, which is
    /// the property the no-missed-points guarantee rests on; half is chosen so
    /// there is margin for the leg's own rounding as well.
    public static let resampleStepRatio: Double = 0.5

    /// Smallest ring this will sweep with, in image pixels. Guards the resample
    /// loop against a division by zero when a caller passes a radius of 0.
    private static let minimumRadius: Double = 0.5

    public init(pointCount: Int, sequence: [Int] = []) {
        self.pointCount = max(0, pointCount)
        var taken: Set<Int> = []
        var filtered: [Int] = []
        filtered.reserveCapacity(sequence.count)
        // Out-of-range and repeated indices are dropped here rather than at every
        // use: a stored sequence is data that came off disk, and the caller
        // should not have to defend against it.
        for index in sequence where index >= 0 && index < self.pointCount && !taken.contains(index) {
            taken.insert(index)
            filtered.append(index)
        }
        self.sequence = filtered
        self.taken = taken
    }

    /// Points the brush has not numbered yet.
    public var remaining: Int { max(0, pointCount - sequence.count) }

    /// Numbered points. The status line's numerator.
    public var swept: Int { sequence.count }

    /// Whether every point has been numbered.
    public var isComplete: Bool { pointCount > 0 && sequence.count >= pointCount }

    /// Whether the brush has numbered nothing at all.
    public var isEmpty: Bool { sequence.isEmpty }

    // MARK: - Sweeping

    /// Numbers every point the ring meets while its centre travels from `from`
    /// to `to`, and reports how many were added by this leg.
    ///
    /// The leg is walked in sub-steps and each one catches what is inside the
    /// ring at that moment, which is what makes a fast drag behave exactly like a
    /// slow one.
    @discardableResult
    public mutating func sweep(points: [PixelPoint],
                               from: PixelPoint,
                               to: PixelPoint,
                               radius: Double) -> Int {
        let radius = max(radius, Self.minimumRadius)
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = (dx * dx + dy * dy).squareRoot()

        let step = radius * Self.resampleStepRatio
        let steps = max(1, Int((distance / step).rounded(.up)))
        var added = 0
        for index in 1...steps {
            let t = Double(index) / Double(steps)
            let centre = PixelPoint(x: from.x + dx * t, y: from.y + dy * t)
            added += capture(points: points, around: centre, radius: radius,
                             direction: (dx: dx, dy: dy))
        }
        return added
    }

    /// Numbers every not-yet-numbered point inside the ring, in the order the
    /// brush reached them.
    ///
    /// `direction` is the brush's motion; pass nil for a press that has not moved
    /// yet, which falls back to ranking by distance from the centre.
    @discardableResult
    public mutating func capture(points: [PixelPoint],
                                 around centre: PixelPoint,
                                 radius: Double,
                                 direction: (dx: Double, dy: Double)?) -> Int {
        let radius = max(radius, Self.minimumRadius)
        let radiusSquared = radius * radius

        // A direction of (0, 0) carries no more information than no direction at
        // all, and dividing by its length would produce NaN keys that sort
        // unpredictably.
        var travel: (dx: Double, dy: Double)? = nil
        if let direction {
            let length = (direction.dx * direction.dx + direction.dy * direction.dy).squareRoot()
            if length > 1e-9 { travel = (direction.dx / length, direction.dy / length) }
        }

        var caught: [(index: Int, key: Double)] = []
        for (index, point) in points.enumerated() where !taken.contains(index) {
            let vx = point.x - centre.x
            let vy = point.y - centre.y
            guard vx * vx + vy * vy <= radiusSquared else { continue }
            if let travel {
                // How far along the motion this point lies. The unit vector makes
                // the key a real distance, so the same threshold means the same
                // thing whatever the leg's length.
                caught.append((index, vx * travel.dx + vy * travel.dy))
            } else {
                caught.append((index, (vx * vx + vy * vy).squareRoot()))
            }
        }
        guard !caught.isEmpty else { return 0 }

        // Ties are broken by index: two points the ring meets at the same instant
        // must still land in a fixed order, or the polyline would depend on how
        // the sort happened to fall.
        caught.sort { $0.key == $1.key ? $0.index < $1.index : $0.key < $1.key }
        for entry in caught {
            taken.insert(entry.index)
            sequence.append(entry.index)
        }
        return caught.count
    }

    // MARK: - Resolving

    /// The points in sweep order, with the ones the brush never reached last and
    /// in their original relative order.
    ///
    /// Putting the stragglers at the end is deliberate. They draw as a polyline
    /// that jumps about the chart, which is exactly the visible signal that the
    /// sweep is unfinished — dropping them instead would silently shorten the
    /// curve, and leaving them at their old indices would interleave them with
    /// the rebuilt run.
    ///
    /// Returns the ordered points and how many leading entries came from the
    /// sweep, so a caller can tell the rebuilt stretch from the pending one
    /// without recomputing the split.
    public static func resolve(_ points: [PixelPoint],
                               sequence: [Int]) -> (points: [PixelPoint], sweptCount: Int) {
        guard !sequence.isEmpty else { return (points, 0) }
        var used = [Bool](repeating: false, count: points.count)
        var ordered: [PixelPoint] = []
        ordered.reserveCapacity(points.count)
        for index in sequence where index >= 0 && index < points.count && !used[index] {
            used[index] = true
            ordered.append(points[index])
        }
        let sweptCount = ordered.count
        for (index, point) in points.enumerated() where !used[index] {
            ordered.append(point)
        }
        return (ordered, sweptCount)
    }

    /// Convenience for callers that only want the points.
    public func resolve(_ points: [PixelPoint]) -> [PixelPoint] {
        Self.resolve(points, sequence: sequence).points
    }

    /// The same resolution expressed as **indices into the stored points**.
    ///
    /// `resolve` answers "what does the curve look like"; this answers "which
    /// stored point is that", which is what an editor needs. Dragging a marker
    /// has to write to the point the user grabbed, and on a curve whose order is
    /// anything but 取点顺序 the displayed position and the stored index are two
    /// different numbers — writing by displayed position would move whichever
    /// point happens to sit at that index and leave the grabbed one where it was.
    ///
    /// Kept beside `resolve` and asserted equal to it in the tests
    /// (`points[indices] == resolve(points)`), because two ways of computing one
    /// order is exactly how the two drift apart.
    public static func resolveIndices(pointCount: Int,
                                      sequence: [Int]) -> (indices: [Int], sweptCount: Int) {
        guard pointCount > 0 else { return ([], 0) }
        guard !sequence.isEmpty else { return (Array(0..<pointCount), 0) }
        var used = [Bool](repeating: false, count: pointCount)
        var ordered: [Int] = []
        ordered.reserveCapacity(pointCount)
        for index in sequence where index >= 0 && index < pointCount && !used[index] {
            used[index] = true
            ordered.append(index)
        }
        let sweptCount = ordered.count
        for index in 0..<pointCount where !used[index] { ordered.append(index) }
        return (ordered, sweptCount)
    }
}
