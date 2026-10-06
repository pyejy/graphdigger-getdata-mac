import Foundation

/// How a curve's extracted points should be presented and exported.
///
/// Order is not cosmetic: consecutive points define the polyline, so a curve
/// that doubles back, or one whose points were taken right-to-left, is wrong
/// unless the order can be corrected. The extraction order is always kept in
/// `CurveLine.points`, so no mode destroys information and the user can always
/// return to the original.
///
/// All but one of these modes are pure functions of the point positions.
/// `.swept` is the exception and is documented as such: it presents a sequence
/// that a person drew with the ring brush, which lives on the curve.
public enum PointOrder: String, CaseIterable, Codable, Sendable {
    /// Exactly the order the points were taken in.
    case extraction
    /// Left to right, which is what a plot of `y(x)` needs.
    case ascendingX
    /// Right to left.
    case descendingX
    /// Runs the sequence backwards — handy after tracing from the wrong end.
    case reversed
    /// The order the «点重排» ring brush swept the points in.
    ///
    /// The odd one out among these cases: it is **not** a function of the point
    /// positions, because the correct order on a curve that doubles back is
    /// whatever the person dragging the ring had in mind. The sequence itself
    /// therefore lives on `CurveLine.sweptOrder`, and this case only marks that
    /// it is the one being shown. `apply(to:)` on its own returns the original
    /// order, and `CurveLine.orderedPoints` is what actually resolves it.
    case swept

    public var displayName: String {
        switch self {
        case .extraction:  return "取点顺序"
        case .ascendingX:  return "X 升序"
        case .descendingX: return "X 降序"
        case .reversed:    return "反转顺序"
        case .swept:       return "重排顺序"
        }
    }

    /// Points in this order. Stable: equal keys keep their extraction order, so
    /// a column of points sharing an x does not get shuffled arbitrarily.
    ///
    /// Expressed through `applyIndices`, deliberately: the two must never
    /// disagree, and the only way to guarantee that is to have one of them be a
    /// lookup of the other. `GDCoreTests` asserts the relationship rather than
    /// trusting it.
    public func apply(to points: [PixelPoint]) -> [PixelPoint] {
        applyIndices(to: points).map { points[$0] }
    }

    /// The same order, as **indices into `points`** rather than as a copy.
    ///
    /// Needed by anything that *edits* the points rather than just drawing them.
    /// A sorted or reversed order is a permutation, so on such a curve the
    /// position a marker is drawn at and the index it is stored at are different
    /// numbers; an editor that used one for the other would move the wrong point
    /// and look like it had moved the right one.
    public func applyIndices(to points: [PixelPoint]) -> [Int] {
        switch self {
        case .extraction:
            return Array(points.indices)
        case .reversed:
            return Array(points.indices.reversed())
        case .ascendingX:
            return Self.stableSortedIndices(points, by: { $0.x < $1.x })
        case .descendingX:
            return Self.stableSortedIndices(points, by: { $0.x > $1.x })
        case .swept:
            // Deliberately the original order. The sweep's own sequence is not
            // part of the point set, so it cannot be applied from here — see the
            // note on the case. Falling back to the extraction order is the
            // honest answer rather than an empty or arbitrary one, and it is what
            // a curve with no sweep recorded should show.
            return Array(points.indices)
        }
    }

    /// `Array.sorted(by:)` makes no stability promise, so ties are broken by
    /// position explicitly.
    private static func stableSortedIndices(_ points: [PixelPoint],
                                            by precedes: (PixelPoint, PixelPoint) -> Bool) -> [Int] {
        points.indices
            .sorted { a, b in
                if precedes(points[a], points[b]) { return true }
                if precedes(points[b], points[a]) { return false }
                return a < b
            }
    }
}

/// Whether an ordered run of points actually advances left to right, and how
/// often it doubles back. Used to warn about an order that will plot badly.
public struct OrderDiagnosis: Equatable, Sendable {
    public let isMonotonicInX: Bool
    public let reversals: Int
    public let spanX: ClosedRange<Double>?

    public init(points: [PixelPoint]) {
        guard points.count >= 2 else {
            isMonotonicInX = true
            reversals = 0
            spanX = points.first.map { $0.x...$0.x }
            return
        }
        // A reversal is a *change* of direction, not every descending step: a
        // curve taken right to left is monotonic, and reporting its every step as
        // a fold-back would bury the real problem under a false warning.
        var increasing = true, decreasing = true
        var changes = 0
        var previousDirection = 0
        for (a, b) in zip(points, points.dropFirst()) {
            if b.x > a.x { decreasing = false }
            if b.x < a.x { increasing = false }
            let direction = b.x > a.x ? 1 : (b.x < a.x ? -1 : 0)
            if direction == 0 { continue }
            if previousDirection != 0 && direction != previousDirection { changes += 1 }
            previousDirection = direction
        }
        isMonotonicInX = increasing || decreasing
        reversals = changes
        let xs = points.map(\.x)
        spanX = (xs.min() ?? 0)...(xs.max() ?? 0)
    }
}
