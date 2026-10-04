import Foundation

/// Area ("grid") digitising — FR-5.2.
///
/// Vertical scan lines spaced `dx` pixels apart sweep the selected rectangle;
/// within each column the foreground is split into runs (a run ends when more
/// than `gap` blank rows separate two foreground rows, so two curves crossing
/// the same column yield two points instead of one merged centroid), and each
/// run contributes its centroid.
///
/// The Python reference this was ported from measured p95 <= 0.24% full-scale
/// error across five curve families; the same synthetic charts are replayed in
/// `GDCoreTests`.
public enum AreaDigitizer {

    /// - Parameters:
    ///   - mask: foreground mask built from the source image.
    ///   - rect: rectangle to sweep, in pixel space; clamped to the image.
    ///   - dx: spacing between scan lines, in pixels. Smaller = denser output.
    /// - Returns: points ordered left to right; several per column when runs separate.
    public static func digitize(mask: ForegroundMask, rect: PixelRect, dx: Int) -> [PixelPoint] {
        precondition(dx >= 1, "dx must be at least 1 pixel")

        let x0 = max(0, min(rect.x0, mask.width - 1))
        let x1 = max(0, min(rect.x1, mask.width - 1))
        let y0 = max(0, min(rect.y0, mask.height - 1))
        let y1 = max(0, min(rect.y1, mask.height - 1))
        guard x1 >= x0, y1 >= y0 else { return [] }

        // A run is broken by a blank stretch longer than `gap`.
        let gap = max(3, dx)
        var points: [PixelPoint] = []

        var x = x0
        while x <= x1 {
            var runStart = -1
            var runSum = 0
            var runCount = 0
            var lastForegroundRow = -1

            for y in y0...y1 {
                if mask.isForeground(x: x, y: y) {
                    if runStart < 0 {
                        runStart = y
                        runSum = 0
                        runCount = 0
                    } else if y - lastForegroundRow > gap {
                        points.append(centroid(x: x, sum: runSum, count: runCount))
                        runSum = 0
                        runCount = 0
                    }
                    runSum += y
                    runCount += 1
                    lastForegroundRow = y
                }
            }
            if runCount > 0 {
                points.append(centroid(x: x, sum: runSum, count: runCount))
            }

            x += dx
        }

        return points
    }

    /// Mean row of a run, offset by half a pixel so the result names the centre
    /// of the pixel rather than its top-left corner.
    @inline(__always)
    private static func centroid(x: Int, sum: Int, count: Int) -> PixelPoint {
        PixelPoint(x: Double(x), y: Double(sum) / Double(count) + 0.5)
    }
}
