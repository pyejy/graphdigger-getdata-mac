import Foundation

/// Finds the symbols of a scatter plot: one point per glyph, at its centre.
///
/// The other two digitizers both assume the curve is a **path**. Area digitising
/// samples column by column, asking "where does the ink cross this column"; auto
/// trace walks along the ink from a seed. Neither has an answer for a scatter
/// plot, where the data are a set of disconnected glyphs: a column through a
/// circle crosses it twice and the scan returns two points for one datum, and a
/// walk from a seed stops at the edge of the glyph it started on. The tools are
/// not wrong on such a chart — they are answering a question the chart is not
/// posing.
///
/// What a scatter plot needs is the question "where are the glyphs", and that is
/// a connected-components problem: flood the mask, and take one point per
/// component. What makes it usable rather than merely correct is the filtering —
/// a chart's ink is not all data. The same colour appears in a legend key, in a
/// fitted line drawn through the points, in an axis stroke that happens to be
/// tinted, and in the ragged anti-aliased fringe of every one of those. A
/// component that is far too big is a blob or a line, one that is far too small
/// is speckle, and one that is long and thin is a line rather than a glyph. The
/// filters are what turn "find the ink" into "find the data", and the counts of
/// what they threw away are returned so the user can tell a mis-set size from a
/// chart with nothing on it.
///
/// **The order of the result is reading order** — left to right, and top to
/// bottom within a column. A scatter plot has no inherent order (that absence is
/// what distinguishes it from a line chart), so the extraction sequence is not
/// information the way it is for a traced curve. Reading order is the order a
/// table of the same data would be written in, and the curve's own order setting
/// can still re-sort it afterwards.
public enum SymbolMatcher {

    /// What counts as a symbol.
    ///
    /// One knob, because a user reading a chart off the screen can estimate the
    /// size of a marker and cannot estimate its area fill fraction. Everything
    /// else is derived from that estimate, with the tolerances wide enough to
    /// absorb anti-aliasing and a coarse colour threshold — the two things that
    /// move a glyph's measured size away from its nominal one.
    public struct Options: Equatable, Sendable {
        /// The symbol's diameter in image pixels, as measured on screen.
        public var expectedDiameter: Double

        /// Accepted area, as multiples of the area that diameter implies.
        ///
        /// The upper bound is the one that matters, and it is tight on purpose.
        /// Measured on the renderer's own fixtures at an 11-pixel diameter: a
        /// single marker's ink comes out at **97 pixels** against a nominal 95
        /// (1.02×), while **two markers that touch measure 194 to 279** (2.0× to
        /// 2.9×). Anything up to 2.2 — the obvious first guess — therefore admits
        /// a merged pair as "one slightly large symbol" and returns a *point that
        /// is on no marker at all*, silently, on exactly the crowded charts where
        /// the count matters. 1.7 separates them with room on both sides: a
        /// marker's anti-aliased fringe adds about its perimeter, which for this
        /// size is +0.36×, so a legitimate single still has 23% of margin while
        /// the closest merged pair is 20% over the line.
        ///
        /// The lower bound stays generous because a marker clipped by the plot
        /// edge is legitimately half a glyph, and rejecting it would drop a real
        /// datum at the boundary of the chart.
        public var minAreaFactor: Double
        public var maxAreaFactor: Double

        /// Long side over short side of the bounding box. A circle, square or
        /// triangle is near 1; a dash of a connecting line is far above it. This
        /// is the filter that keeps a fitted line's segments out of a scatter.
        public var maxAspectRatio: Double

        /// Ink as a fraction of the bounding box. A square fills 1.0, a circle
        /// 0.785, a triangle 0.5, a crossed or hollow glyph about 0.4 — and a
        /// straight diagonal segment of a line stays far below all of them.
        public var minFillRatio: Double

        public init(expectedDiameter: Double,
                    minAreaFactor: Double = 0.30,
                    maxAreaFactor: Double = 1.70,
                    maxAspectRatio: Double = 2.5,
                    minFillRatio: Double = 0.28) {
            self.expectedDiameter = expectedDiameter
            self.minAreaFactor = minAreaFactor
            self.maxAreaFactor = maxAreaFactor
            self.maxAspectRatio = maxAspectRatio
            self.minFillRatio = minFillRatio
        }
    }

    /// What was found, and what was not.
    ///
    /// The three rejection counts are the point of returning a struct rather
    /// than an array. "Found 8 symbols" reads as a chart with eight points, and
    /// the honest reading is often "the size is wrong" — four hundred specks of
    /// one pixel and one blob the size of the plot says the estimate is far too
    /// small, and without the counts that chart and an empty one look identical.
    public struct Result: Equatable, Sendable {
        /// Accepted glyph centres, in reading order.
        public var points: [PixelPoint]
        /// Components smaller than the area window — speckle, and the ragged
        /// fringes anti-aliasing leaves beside a glyph.
        public var rejectedTooSmall: Int
        /// Components larger than it — a legend key, a blob, two markers that
        /// touch, or a fitted line.
        public var rejectedTooLarge: Int
        /// Components of an admissible size but the wrong shape: long and thin
        /// (a line), or too sparse for their box (a hollow outline).
        public var rejectedOddShape: Int
        /// Every foreground component examined, accepted or not.
        public var componentCount: Int

        public init(points: [PixelPoint] = [],
                    rejectedTooSmall: Int = 0,
                    rejectedTooLarge: Int = 0,
                    rejectedOddShape: Int = 0,
                    componentCount: Int = 0) {
            self.points = points
            self.rejectedTooSmall = rejectedTooSmall
            self.rejectedTooLarge = rejectedTooLarge
            self.rejectedOddShape = rejectedOddShape
            self.componentCount = componentCount
        }

        /// Whether anything at all was rejected, for the status line to mention
        /// only when it happened.
        public var hasRejections: Bool {
            rejectedTooSmall + rejectedTooLarge + rejectedOddShape > 0
        }
    }

    public static func match(mask: ForegroundMask, options: Options) -> Result {
        let w = mask.width, h = mask.height
        guard w > 0, h > 0, options.expectedDiameter > 0 else { return Result() }

        let expectedArea = Double.pi / 4 * options.expectedDiameter * options.expectedDiameter
        let minArea = max(1, Int((expectedArea * options.minAreaFactor).rounded()))
        let maxArea = max(minArea, Int((expectedArea * options.maxAreaFactor).rounded()))

        // One byte per pixel of bookkeeping, not one per component: a component
        // can be half the image, and a stack of pixel indices for one that size
        // would be tens of megabytes. The flood below walks **spans** instead, so
        // the stack holds a few rows' worth of run starts whatever the picture is.
        var visited = [Bool](repeating: false, count: w * h)
        var accepted: [PixelPoint] = []
        var tooSmall = 0, tooLarge = 0, oddShape = 0, components = 0
        var stack: [Int] = []          // packed `y * w + x` seeds

        for start in 0..<(w * h) {
            guard mask.bits[start], !visited[start] else { continue }
            components += 1
            stack.removeAll(keepingCapacity: true)
            stack.append(start)

            var count = 0
            var sumX = 0, sumY = 0
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min

            while let seed = stack.popLast() {
                let y = seed / w
                let rowStart = y * w

                // The run this seed belongs to, grown both ways over unvisited
                // foreground. Stopping at a visited pixel is safe rather than
                // merely convenient: a visited pixel is already counted, so the
                // shorter run loses nothing, and the pixels beyond it are reached
                // by whichever span claimed them.
                var left = seed
                while left > rowStart, mask.bits[left - 1], !visited[left - 1] { left -= 1 }
                var right = seed
                while right < rowStart + w - 1, mask.bits[right + 1], !visited[right + 1] { right += 1 }

                for index in left...right {
                    visited[index] = true
                    let x = index - rowStart
                    count += 1
                    sumX += x
                    sumY += y
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
                if y < minY { minY = y }
                if y > maxY { maxY = y }

                // Seed the rows above and below, once per contiguous run so the
                // stack grows with the number of runs and not with their length.
                //
                // **The scan is widened by one column on each side**, and that is
                // not slack: connectivity here is 8-way, so a run one column
                // outside this span is still joined to it diagonally. Scanning
                // only the span's own columns splits exactly the shapes drawn
                // along a diagonal — the staircase of three-pixel runs that any
                // slanted stroke or dash is — into one component per run. Measured
                // on a one-pixel-wide diagonal: **97 components instead of 1**,
                // all of them then rejected as speckle, so the line vanished and
                // took the count of rejected specks with it.
                //
                // The run is tracked as **indices** (that is what the stack holds
                // and what the marking loop walks) and the neighbour rows are
                // indexed by **column**, so the two have to be converted here.
                let leftColumn = left - rowStart
                let rightColumn = right - rowStart
                for neighbour in [y - 1, y + 1] where neighbour >= 0 && neighbour < h {
                    let base = neighbour * w
                    var x = max(0, leftColumn - 1)
                    let lastColumn = min(w - 1, rightColumn + 1)
                    while x <= lastColumn {
                        if mask.bits[base + x], !visited[base + x] {
                            stack.append(base + x)
                            while x <= lastColumn, mask.bits[base + x] { x += 1 }
                        } else {
                            x += 1
                        }
                    }
                }
            }

            if count < minArea { tooSmall += 1; continue }
            if count > maxArea { tooLarge += 1; continue }
            let boxWidth = maxX - minX + 1
            let boxHeight = maxY - minY + 1
            let aspect = Double(max(boxWidth, boxHeight)) / Double(min(boxWidth, boxHeight))
            let fill = Double(count) / Double(boxWidth * boxHeight)
            if aspect > options.maxAspectRatio || fill < options.minFillRatio {
                oddShape += 1
                continue
            }
            // The **centre of mass of the ink**, not the centre of the bounding
            // box. The box centre is the obvious first implementation and it is
            // wrong in a specific, quiet way: a triangle's box centre sits off
            // its ink by half the glyph's asymmetry, so a chart read that way is
            // systematically biased — invisible on screen, wrong in the data. For
            // a symmetric glyph the two agree, which is exactly why the mistake
            // survives a test written against circles alone. (There is one in
            // `SymbolMatcherTests` that uses triangles for that reason.)
            accepted.append(PixelPoint(x: Double(sumX) / Double(count),
                                       y: Double(sumY) / Double(count)))
        }

        // Reading order. Ties on x are broken by y so the result does not depend
        // on the order the flood happened to find the components in, which for a
        // scan from the top left is the same thing — but the scan's order is an
        // implementation detail and this line is a promise.
        accepted.sort { lhs, rhs in
            lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x
        }
        return Result(points: accepted,
                      rejectedTooSmall: tooSmall,
                      rejectedTooLarge: tooLarge,
                      rejectedOddShape: oddShape,
                      componentCount: components)
    }
}
