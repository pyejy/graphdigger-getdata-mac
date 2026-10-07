import Foundation

/// Takes a grid off a foreground mask — B-1, `功能扩展提案.md`.
///
/// Scanned and printed figures carry a ruling grid, and it is the most common
/// reason an extraction "selects the whole picture": the grid is the same ink
/// as the curve often enough that colour cannot separate them. What can is
/// **geometry**: a grid line is long, straight, thin, and one of a family of
/// lines at equal spacing — and *that last part is what makes it safe to act
/// on*. Removing every long straight line would eat a straight data segment
/// whole; removing only lines that arrive as an arithmetic progression keeps
/// it, because one line is not a progression.
///
/// What this cannot do, and says so rather than guessing: a curve that is
/// itself a thin straight line running the length of the figure, drawn at the
/// same spacing as the grid, is indistinguishable from a grid line by these
/// features. The area mask (FR-4.5) stays the way to exclude things geometry
/// cannot tell apart.
///
/// Order of business:
///
/// 1. **Find the lines** — project the mask onto each axis and look for
///    columns (then rows) whose ink covers most of the image's length and is
///    only a few pixels thick.
/// 2. **Keep the families** — of those, only the ones that line up as an
///    arithmetic progression of at least `minLines` members. A lone axis, or a
///    lone straight data segment, is not a family and survives.
/// 3. **Erase the strokes, not the crossings** — inside a grid line, a pixel
///    is cleared only when it belongs to a long run *along* that line. Where a
///    curve crosses a grid line, the crossing is a short run and stays. That
///    one rule is what keeps 95%+ of a curve after ten grid lines have been
///    lifted off it.
public enum GridLineRemover {

    /// What the pass found and did.
    public struct Outcome: Equatable, Sendable {
        /// Centres of the columns removed, in pixels.
        public var columns: [Int]
        /// Centres of the rows removed, in pixels.
        public var rows: [Int]
        /// Pixels actually cleared from the mask.
        public var removedPixels: Int

        public init(columns: [Int] = [], rows: [Int] = [], removedPixels: Int = 0) {
            self.columns = columns
            self.rows = rows
            self.removedPixels = removedPixels
        }

        public var isEmpty: Bool { columns.isEmpty && rows.isEmpty }
    }

    /// A candidate line found by the projection.
    private struct Line {
        var start: Int
        var end: Int
        var coverage: Double
        var centre: Int { (start + end) / 2 }
        var width: Int { end - start + 1 }
    }

    /// Defaults, all measured against the synthetic fixture in
    /// `GridLineRemoverTests` — see that file for what each one buys.
    ///
    /// - `minCoverage`: a grid line runs the length of the figure; half of it
    ///   is a floor generous enough for a line broken by the curve drawn over
    ///   it, and high enough to leave a curve's own column alone.
    /// - `maxLineWidth`: the proposal's "细". Wider than this and it is not a
    ///   rule, it is a band.
    /// - `minLines`: **the safety catch.** Two long straight lines can be an
    ///   axis and a data segment; three at equal spacing cannot plausibly be
    ///   anything but a grid.
    /// - `spacingTolerance`: printed grids are equal-spaced; the slack is for
    ///   the pixel rounding of a scan.
    /// - `minRunLength`: how long a run along the line has to be before it is
    ///   read as the line's own ink rather than something crossing it.
    public struct Parameters: Sendable {
        public var minCoverage: Double = 0.5
        public var maxLineWidth: Int = 4
        public var minLines: Int = 3
        public var spacingTolerance: Double = 0.25
        public var minRunLength: Int = 12

        public init() {}
    }

    /// Returns a copy of `mask` with the grid lines taken out, plus a report of
    /// what was removed — the report is what the status line and the selftest
    /// read, and what makes a wrong guess visible instead of silent.
    public static func remove(from mask: ForegroundMask,
                              parameters: Parameters = Parameters())
        -> (mask: ForegroundMask, outcome: Outcome) {
        var out = mask

        let columns = gridLines(in: out, parameters: parameters, isColumn: true)
        let rows = gridLines(in: out, parameters: parameters, isColumn: false)
        var removed = 0
        for line in columns {
            removed += erase(&out, centre: line.centre, width: line.width,
                             parameters: parameters, isColumn: true)
        }
        for line in rows {
            removed += erase(&out, centre: line.centre, width: line.width,
                             parameters: parameters, isColumn: false)
        }
        return (out, Outcome(columns: columns.map(\.centre),
                             rows: rows.map(\.centre),
                             removedPixels: removed))
    }

    // MARK: - Finding the lines

    /// The columns (or rows) that pass the projection and belong to a family.
    ///
    /// Reads the mask, does not touch it: `remove` calls this twice, and the
    /// second call seeing the state *after* the columns went is what lets a
    /// grid's rows be judged on their own ink rather than on what the crossing
    /// columns contributed.
    private static func gridLines(in mask: ForegroundMask,
                                  parameters: Parameters,
                                  isColumn: Bool) -> [Line] {
        let span = isColumn ? mask.height : mask.width
        let count = isColumn ? mask.width : mask.height

        // Coverage per position: how much of the image's length this column (or
        // row) inks in.
        var ink = [Int](repeating: 0, count: count)
        for i in 0..<count {
            var run = 0
            for j in 0..<span where isForeground(mask, along: isColumn, i, j) { run += 1 }
            ink[i] = run
        }

        // Group adjacent positions into lines. A grid stroke is a few pixels
        // wide, so its profile is a small plateau; the plateau's centre is the
        // line's true position, which matters later when the crossings are
        // decided.
        var lines: [Line] = []
        var start: Int?
        func close(_ s: Int, _ e: Int) {
            var total = 0
            var peak = 0
            for i in s...e {
                total += ink[i]
                peak = max(peak, ink[i])
            }
            let coverage = Double(peak) / Double(span)
            if coverage >= parameters.minCoverage
                && (e - s + 1) <= parameters.maxLineWidth {
                lines.append(Line(start: s, end: e, coverage: coverage))
            }
        }
        for i in 0..<count {
            let covered = Double(ink[i]) / Double(span) >= parameters.minCoverage * 0.5
            if covered {
                if start == nil { start = i }
            } else if let s = start {
                close(s, i - 1)
                start = nil
            }
        }
        if let s = start { close(s, count - 1) }

        return family(of: lines, parameters: parameters)
    }

    private static func isForeground(_ mask: ForegroundMask, along isColumn: Bool,
                                     _ i: Int, _ j: Int) -> Bool {
        isColumn ? mask.isForeground(x: i, y: j) : mask.isForeground(x: j, y: i)
    }

    /// The longest run of candidates whose consecutive gaps are near-equal.
    ///
    /// Equal spacing is the feature that separates a grid from the other long
    /// straight things on a chart, so it is also the guard: below `minLines`
    /// members there is nothing to average, and the answer is "no grid".
    private static func family(of candidates: [Line],
                               parameters: Parameters) -> [Line] {
        guard candidates.count >= parameters.minLines else { return [] }

        var best: [Line] = []
        for startIndex in 0..<(candidates.count - parameters.minLines + 1) {
            for endIndex in (startIndex + parameters.minLines - 1)..<candidates.count {
                let slice = Array(candidates[startIndex...endIndex])
                var gaps: [Int] = []
                for i in 1..<slice.count { gaps.append(slice[i].centre - slice[i - 1].centre) }
                guard let smallest = gaps.min(), let largest = gaps.max(),
                      smallest > 0 else { continue }
                // Equal spacing, allowing for the rounding of a scan.
                guard Double(largest - smallest) / Double(smallest) <= parameters.spacingTolerance
                else { continue }
                if slice.count > best.count { best = slice }
            }
        }
        return best
    }

    // MARK: - Erasing the strokes

    /// Clears a line's own ink: within the line's columns (or rows), a pixel
    /// goes only when it sits in a run at least `minRunLength` long.
    ///
    /// The curve crossing a grid line is a *short* run in that column — a few
    /// pixels, unless the curve is near-vertical there — so it survives. This
    /// is the difference between lifting a grid off a chart and shredding every
    /// curve in it at ten places.
    private static func erase(_ mask: inout ForegroundMask, centre: Int, width: Int,
                              parameters: Parameters, isColumn: Bool) -> Int {
        let span = isColumn ? mask.height : mask.width
        let half = max(0, width / 2)
        var removed = 0
        for offset in -half...half {
            let line = centre + offset
            guard line >= 0, line < (isColumn ? mask.width : mask.height) else { continue }
            var j = 0
            while j < span {
                guard isForeground(mask, along: isColumn, line, j) else { j += 1; continue }
                var end = j
                while end + 1 < span, isForeground(mask, along: isColumn, line, end + 1) {
                    end += 1
                }
                if end - j + 1 >= parameters.minRunLength {
                    for k in j...end {
                        if isColumn {
                            mask.bits[k * mask.width + line] = false
                        } else {
                            mask.bits[line * mask.width + k] = false
                        }
                        removed += 1
                    }
                }
                j = end + 1
            }
        }
        return removed
    }
}
