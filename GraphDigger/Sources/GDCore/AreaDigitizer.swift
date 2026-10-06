import Foundation

/// Which way the region digitizer's scan lines run — FR-5.4.
///
/// The choice is not cosmetic and not a speed knob: it decides **which curves can
/// be sampled at all**. A vertical scan line meets a single-valued `y = f(x)`
/// once, which is exactly what `.x` wants; it meets a closed loop or a sideways
/// bulge several times, and then a column-by-column sweep produces points that
/// are both out of order *and* missing branches. Turning the grid a quarter turn
/// is what fixes those, and it is why the original offers both.
public enum GridAxis: String, CaseIterable, Codable, Sendable {
    /// Scan lines are vertical and advance left to right — one sample per column.
    /// The right choice for `y = f(x)`.
    case x
    /// Scan lines are horizontal and advance top to bottom — one sample per row.
    /// The right choice when a single x has several y: loops, hysteresis curves,
    /// vertical runs.
    case y

    public var displayName: String {
        switch self {
        case .x: return "X 网格"
        case .y: return "Y 网格"
        }
    }

    /// One line of explanation, for the menu and the status strip.
    public var hint: String {
        switch self {
        case .x: return "扫描线竖直、从左到右 —— 适合单值曲线 y=f(x)"
        case .y: return "扫描线水平、从上到下 —— 适合同一个 x 有多个 y 的曲线(闭合环、竖直段)"
        }
    }
}

/// Area ("grid") digitising — FR-5.2.
///
/// Scan lines spaced `dx` pixels apart sweep the selected rectangle — vertical
/// for `GridAxis.x`, horizontal for `.y`; within each line the foreground is
/// split into runs (a run ends when more than `gap` blank pixels separate two
/// foreground pixels, so two curves crossing the same line yield two points
/// instead of one merged centroid), and each run contributes its mean position.
///
/// The Python reference this was ported from measured p95 <= 0.24% full-scale
/// error across five curve families; the same synthetic charts are replayed in
/// `GDCoreTests`.
public enum AreaDigitizer {

    /// - Parameters:
    ///   - mask: foreground mask built from the source image.
    ///   - rect: rectangle to sweep, in pixel space; clamped to the image.
    ///   - dx: spacing between scan lines, in pixels. Smaller = denser output.
    ///   - axis: which way the scan lines run. See `GridAxis`.
    ///   - phase: where the grid sits, as an **absolute** pixel offset — FR-5.5.
    ///     The scan lines are the lattice `phase + k·dx`, and the rectangle only
    ///     clips them. Absolute rather than relative to the rectangle on purpose:
    ///     the point of a phase is to make a line pass through one particular
    ///     pixel, which is a fact about the picture, not about the box the user
    ///     happened to drag. A relative offset would slide the whole grid every
    ///     time the selection was redrawn, so a user who aligned the grid once
    ///     would have to align it again after every pass.
    ///
    ///     Folded into `0..<dx`: moving a grid by exactly one spacing reproduces
    ///     it, so anything else would let two phases that draw identically
    ///     compare unequal — and this value is persisted state.
    ///
    /// - Returns: points in scan order — left to right for `.x`, top to bottom
    ///   for `.y` — several per line where runs separate.
    ///
    /// **The two axes are exact transposes of each other.** Scanning an image
    /// with `.x` and scanning its transpose with `.y` give the same points,
    /// swapped. That is asserted in `GDCoreTests` rather than left as a claim,
    /// because it is the property that makes 「Y 网格」 trustworthy: it says the
    /// new axis is the same algorithm seen from another side, not a second
    /// implementation that happens to look similar on one picture.
    public static func digitize(mask: ForegroundMask,
                               rect: PixelRect,
                               dx: Int,
                               axis: GridAxis = .x,
                               phase: Int = 0) -> [PixelPoint] {
        precondition(dx >= 1, "dx must be at least 1 pixel")

        let x0 = max(0, min(rect.x0, mask.width - 1))
        let x1 = max(0, min(rect.x1, mask.width - 1))
        let y0 = max(0, min(rect.y0, mask.height - 1))
        let y1 = max(0, min(rect.y1, mask.height - 1))
        guard x1 >= x0, y1 >= y0 else { return [] }

        // A run is broken by a blank stretch longer than `gap`.
        let gap = max(3, dx)
        let lattice = Self.foldedPhase(phase, dx: dx)

        switch axis {
        case .x:
            return scanColumns(mask: mask, first: Self.firstLine(notBefore: x0, phase: lattice, dx: dx),
                               through: x1, rows: y0...y1, dx: dx, gap: gap)
        case .y:
            return scanRows(mask: mask, first: Self.firstLine(notBefore: y0, phase: lattice, dx: dx),
                            through: y1, columns: x0...x1, dx: dx, gap: gap)
        }
    }

    /// Maps any phase onto `0..<dx`, including negative ones.
    public static func foldedPhase(_ phase: Int, dx: Int) -> Int {
        precondition(dx >= 1, "dx must be at least 1 pixel")
        return ((phase % dx) + dx) % dx
    }

    /// The smallest lattice line at or after `origin`.
    ///
    /// The grid is anchored to the picture rather than to the selection, so the
    /// first line inside a rectangle is usually *not* its edge — it is the first
    /// multiple-of-`dx`-plus-phase that the edge has already passed.
    private static func firstLine(notBefore origin: Int, phase: Int, dx: Int) -> Int {
        origin + ((phase - origin) % dx + dx) % dx
    }

    // MARK: - The two sweeps

    private static func scanColumns(mask: ForegroundMask, first: Int, through last: Int,
                                    rows: ClosedRange<Int>,
                                    dx: Int, gap: Int) -> [PixelPoint] {
        var points: [PixelPoint] = []
        var column = first
        while column <= last {
            var run = RunScan(gap: gap)
            for row in rows where mask.isForeground(x: column, y: row) {
                run.add(row)
            }
            run.finish()
            // The scan line's own coordinate is the column index, while the run's
            // is a mean of row indices — and a mean of indices names the *edge* of
            // the average pixel, so it takes the half-pixel step and the column
            // does not. Kept exactly as the ported algorithm had it: this is the
            // convention the accuracy figures and every stored point were
            // measured under.
            for meanRow in run.means {
                points.append(PixelPoint(x: Double(column), y: meanRow))
            }
            column += dx
        }
        return points
    }

    private static func scanRows(mask: ForegroundMask, first: Int, through last: Int,
                                 columns: ClosedRange<Int>,
                                 dx: Int, gap: Int) -> [PixelPoint] {
        var points: [PixelPoint] = []
        var row = first
        while row <= last {
            var run = RunScan(gap: gap)
            for column in columns where mask.isForeground(x: column, y: row) {
                run.add(column)
            }
            run.finish()
            // The transpose of `scanColumns`: the fixed coordinate stays as it is
            // and the run's mean takes the half-pixel step, so swapping the axes
            // swaps the coordinates and changes nothing else.
            for meanColumn in run.means {
                points.append(PixelPoint(x: meanColumn, y: Double(row)))
            }
            row += dx
        }
        return points
    }

    // MARK: - Run bookkeeping

    /// Collects the mean index of each run of foreground along one scan line.
    ///
    /// A run ends when a blank stretch longer than `gap` interrupts it — the rule
    /// that lets a line crossed twice by two separate curves produce two points
    /// rather than one centroid sitting in the empty space between them.
    ///
    /// Mean of indices plus half a pixel, so the result names the centre of the
    /// average pixel rather than its top-left corner.
    private struct RunScan {
        let gap: Int
        private var last = 0
        private var sum = 0
        private var count = 0
        private(set) var means: [Double] = []

        init(gap: Int) { self.gap = gap }

        mutating func add(_ index: Int) {
            // `count > 0` first: on the very first pixel `last` holds nothing, and
            // comparing against it would both be meaningless and overflow if it
            // were initialised to `Int.min`.
            if count > 0 && index - last > gap { flush() }
            sum += index
            count += 1
            last = index
        }

        mutating func finish() { flush() }

        private mutating func flush() {
            guard count > 0 else { return }
            means.append(Double(sum) / Double(count) + 0.5)
            sum = 0
            count = 0
        }
    }
}
