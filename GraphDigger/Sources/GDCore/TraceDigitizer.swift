import Foundation

/// Automatic line tracing — FR-5.1.
///
/// Walks a connected stroke from a seed pixel, following a smoothed heading and
/// bridging dashes. Stops at a dead end or when a junction is detected, in which
/// case the branch cell is reported so the UI can ask which arm to follow.
///
/// Ported from the Phase 0 Python reference, which validated against synthetic
/// charts (full-length traces on solid and dashed curves, correct stop at a
/// perpendicular crossing, no false stop on a steep log-scale curve).
public enum TraceDigitizer {

    /// Tunables. Defaults are the values the reference implementation validated.
    public struct Options: Sendable {
        /// How far ahead, in pixels, the walker may jump across a blank gap.
        public var bridgePixels: Int = 4
        /// Radius of the perpendicular profile scan used for junction detection.
        public var profileRadius: Int = 7
        /// Minimum lateral distance, in pixels, for a blob to count as off-axis.
        public var minLateral: Double = 2.0
        /// Consecutive steps both sides must stay occupied before a junction counts.
        public var persistence: Int = 3
        /// Required difference in how deep the two sides' extremes reach.
        public var divergenceDepth: Double = 3.0
        /// Widest deviation from the heading still accepted as "forward".
        public var forwardFanDegrees: Double = 70.0
        /// Safety valve against pathological masks.
        public var maxPoints: Int = 200_000

        public init() {}
    }

    public struct Result: Sendable {
        public var points: [PixelPoint]
        /// Non-nil when the walk stopped at a junction: the cell on the other arm.
        public var branchPoint: PixelPoint?
        public init(points: [PixelPoint], branchPoint: PixelPoint?) {
            self.points = points
            self.branchPoint = branchPoint
        }
    }

    public static func trace(mask: ForegroundMask,
                             from start: PixelPoint,
                             options: Options = Options()) throws -> Result {
        let w = mask.width, h = mask.height
        let sx = Int(start.x.rounded(.toNearestOrEven)), sy = Int(start.y.rounded(.toNearestOrEven))
        guard sx >= 0, sx < w, sy >= 0, sy < h, mask.isForeground(x: sx, y: sy) else {
            throw GeometryError.startNotOnForeground
        }

        var visited = [Bool](repeating: false, count: w * h)
        var points: [PixelPoint] = [PixelPoint(x: Double(sx), y: Double(sy))]
        var curX = sx, curY = sy
        visited[sy * w + sx] = true

        var heading: Double? = nil
        var posRun = 0, negRun = 0
        var farPos: (depth: Int, offset: Double)? = nil
        var farNeg: (depth: Int, offset: Double)? = nil

        let fanLimit = options.forwardFanDegrees * .pi / 180.0
        let fanSlack = 35.0 * .pi / 180.0
        let lateralLimit = options.minLateral

        @inline(__always)
        func norm(_ a: Double) -> Double {
            var v = (a + .pi).truncatingRemainder(dividingBy: 2 * .pi)
            if v < 0 { v += 2 * .pi }
            return v - .pi
        }

        // Free = in-bounds, foreground, not yet visited.
        @inline(__always)
        func freeNeighbors(_ x: Int, _ y: Int, into out: inout [Int]) {
            out.removeAll(keepingCapacity: true)
            for oy in -1...1 {
                for ox in -1...1 where !(ox == 0 && oy == 0) {
                    let nx = x + ox, ny = y + oy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let idx = ny * w + nx
                    if mask.bits[idx] && !visited[idx] { out.append(idx) }
                }
            }
        }

        var candidates: [Int] = []
        candidates.reserveCapacity(8)

        while points.count < options.maxPoints {
            let ux: Double = heading.map { cos($0) } ?? 1.0
            let uy: Double = heading.map { sin($0) } ?? 0.0

            freeNeighbors(curX, curY, into: &candidates)

            var chosen: Int? = nil

            if heading == nil {
                // Seed direction: prefer rightward travel, else whatever exists.
                var best: Int? = nil
                var bestDY = Int.max
                for idx in candidates {
                    let qx = idx % w, qy = idx / w
                    guard qx > curX else { continue }
                    let dy = abs(qy - curY)
                    if dy < bestDY { bestDY = dy; best = idx }
                }
                if best == nil {
                    for idx in candidates {
                        let qy = idx / w
                        let dy = abs(qy - curY)
                        if dy < bestDY { bestDY = dy; best = idx }
                    }
                }
                chosen = best
            } else {
                var scored: [(Double, Int)] = []
                scored.reserveCapacity(candidates.count)
                for idx in candidates {
                    let qx = idx % w, qy = idx / w
                    let ang = norm(atan2(Double(qy - curY), Double(qx - curX)) - heading!)
                    scored.append((abs(ang), idx))
                }
                scored.sort { $0.0 < $1.0 }
                let forward = scored.filter { $0.0 <= fanLimit }
                if !forward.isEmpty {
                    let bestD = forward[0].0
                    var pool = forward.filter { $0.0 <= bestD + fanSlack }
                    // Among near-equally-aligned cells take the most forward one.
                    var bestProjection = -Double.infinity
                    var bestIdx = pool[0].1
                    for (_, idx) in pool {
                        let qx = idx % w, qy = idx / w
                        let proj = Double(qx - curX) * ux + Double(qy - curY) * uy
                        if proj > bestProjection { bestProjection = proj; bestIdx = idx }
                    }
                    pool.removeAll(keepingCapacity: false)
                    chosen = bestIdx
                }
            }

            guard let nextIdx = chosen else {
                // Dead end: try to bridge a dash along (or near) the heading.
                var landing: (distance: Double, idx: Int)? = nil
                if let hd0 = heading {
                    for offsetDeg in [0.0, 8.0, -8.0] {
                        let hd = hd0 + offsetDeg * .pi / 180.0
                        let rx = cos(hd), ry = sin(hd)
                        var bestDistance: Double? = nil
                        var bestIdx: Int? = nil
                        for k10 in 10...((options.bridgePixels + 1) * 10 - 1) {
                            let k = Double(k10) / 10.0
                            let fx = Int((Double(curX) + rx * k).rounded(.toNearestOrEven))
                            let fy = Int((Double(curY) + ry * k).rounded(.toNearestOrEven))
                            guard fx >= 0, fx < w, fy >= 0, fy < h else { continue }
                            let idx = fy * w + fx
                            if visited[idx] || !mask.bits[idx] { continue }
                            let ang = abs(norm(atan2(Double(fy - curY), Double(fx - curX)) - hd0))
                            guard ang <= 45.0 * .pi / 180.0 else { continue }
                            let d = (Double(fx - curX) * Double(fx - curX)
                                     + Double(fy - curY) * Double(fy - curY)).squareRoot()
                            if bestDistance == nil || d < bestDistance! {
                                bestDistance = d; bestIdx = idx
                            }
                        }
                        if let bd = bestDistance, let bi = bestIdx,
                           landing == nil || bd < landing!.distance {
                            landing = (bd, bi)
                        }
                    }
                }
                guard let land = landing else { break }
                curX = land.idx % w
                curY = land.idx / w
                visited[land.idx] = true
                points.append(PixelPoint(x: Double(curX), y: Double(curY)))
                continue
            }

            visited[nextIdx] = true
            curX = nextIdx % w
            curY = nextIdx / w
            points.append(PixelPoint(x: Double(curX), y: Double(curY)))

            // Smooth the heading over the trailing window of travel.
            let windowStart = max(0, points.count - 13)
            var vx = 0.0, vy = 0.0
            if points.count - windowStart >= 2 {
                for i in (windowStart + 1)..<points.count {
                    vx += points[i].x - points[i - 1].x
                    vy += points[i].y - points[i - 1].y
                }
            }
            if abs(vx) + abs(vy) > 0 {
                let raw = atan2(vy, vx)
                if let h0 = heading {
                    heading = h0 + 0.5 * norm(raw - h0)
                } else {
                    heading = raw
                }
            }

            // ---- junction detection via perpendicular profiles ---------------
            guard let hdg = heading else { continue }
            let tx = cos(hdg), ty = sin(hdg)
            let px = -ty, py = tx   // perpendicular unit vector

            var profiles: [Int: (pos: [Double], neg: [Double])] = [:]
            for step in 2...options.profileRadius {
                let ix = Int((Double(curX) + tx * Double(step)).rounded(.toNearestOrEven))
                let iy = Int((Double(curY) + ty * Double(step)).rounded(.toNearestOrEven))
                guard ix >= 0, ix < w, iy >= 0, iy < h else { break }

                var offsets: [Int] = []
                for off in (-options.profileRadius)...options.profileRadius {
                    let ox = Int((Double(ix) + px * Double(off)).rounded(.toNearestOrEven))
                    let oy = Int((Double(iy) + py * Double(off)).rounded(.toNearestOrEven))
                    guard ox >= 0, ox < w, oy >= 0, oy < h else { continue }
                    let idx = oy * w + ox
                    if mask.bits[idx] && !visited[idx] { offsets.append(off) }
                }
                guard !offsets.isEmpty else { continue }
                offsets.sort()

                // Cluster consecutive offsets; each cluster is one blob crossing
                // the profile line.
                var clusters: [[Int]] = []
                for k in offsets {
                    if var last = clusters.last, let tail = last.last, k - tail <= 1 {
                        last.append(k)
                        clusters[clusters.count - 1] = last
                    } else {
                        clusters.append([k])
                    }
                }
                let centres = clusters.map { Double($0.reduce(0, +)) / Double($0.count) }
                let rp = centres.filter { $0 >= lateralLimit }
                let rn = centres.filter { $0 <= -lateralLimit }
                if !rp.isEmpty || !rn.isEmpty {
                    profiles[step] = (rp, rn)
                }
            }

            let seenPos = profiles.values.contains { !$0.pos.isEmpty }
            let seenNeg = profiles.values.contains { !$0.neg.isEmpty }
            posRun = seenPos ? posRun + 1 : 0
            negRun = seenNeg ? negRun + 1 : 0

            // Deepest-reaching extreme on each side (depth = first profile step
            // at which the extreme offset appears, taking the last occurrence).
            func extreme(positive: Bool) -> (depth: Int, offset: Double)? {
                var values: [(offset: Double, step: Int)] = []
                for (step, p) in profiles {
                    for o in (positive ? p.pos : p.neg) { values.append((o, step)) }
                }
                guard !values.isEmpty else { return nil }
                let extremeOffset = positive
                    ? values.map(\.offset).max()!
                    : values.map(\.offset).min()!
                let depth = values.filter { $0.offset == extremeOffset }.map(\.step).max()!
                return (depth, extremeOffset)
            }

            if let p = extreme(positive: true) { farPos = p }
            if let n = extreme(positive: false) { farNeg = n }

            if posRun >= options.persistence, negRun >= options.persistence,
               let fp = farPos, let fn = farNeg {
                // Two strokes diverging ahead reach visibly different depths;
                // a single stroke's thickness spreads symmetrically instead.
                if abs(Double(fp.depth - fn.depth)) >= options.divergenceDepth {
                    let pick = abs(fp.offset) <= abs(fn.offset) ? fp : fn
                    let bx = Int((Double(curX) + tx * Double(pick.depth) + px * pick.offset).rounded(.toNearestOrEven))
                    let by = Int((Double(curY) + ty * Double(pick.depth) + py * pick.offset).rounded(.toNearestOrEven))
                    if bx >= 0, bx < w, by >= 0, by < h, mask.bits[by * w + bx] {
                        return Result(points: points,
                                      branchPoint: PixelPoint(x: Double(bx), y: Double(by)))
                    }
                }
            }
        }

        return Result(points: points, branchPoint: nil)
    }

    /// Thins a traced path to one point every `minSpacing` pixels of travel.
    ///
    /// The walk itself visits a pixel at a time, so an unthinned trace gives the
    /// user as many points as the curve is long — hundreds per curve, all of them
    /// real but most of them redundant. This is where the density is chosen.
    ///
    /// **A separate pass over the result, not a spacing inside the walk.** The
    /// walk's junction detection and heading smoothing both read the points it has
    /// produced so far (the heading is smoothed over a trailing window of 13
    /// points, and the profile scan steps along it), so a walk that emitted every
    /// Nth pixel would be smoothing over a different length of curve for every
    /// setting — the same knob would change *which* path gets traced, not merely
    /// how finely it is reported. Thinning afterwards keeps the traced path
    /// identical and changes only the sampling, which is what the user is choosing.
    ///
    /// The kept points are drawn from the walk's own output, never interpolated,
    /// so every point still sits on a pixel the trace actually followed. The last
    /// point is always kept: dropping it would shorten the curve by up to a whole
    /// spacing, and the end of the curve is the part most likely to be inspected.
    ///
    /// - Parameters:
    ///   - points: the traced path, in order.
    ///   - minSpacing: least distance, in pixels, between two kept points. 1 or
    ///     less returns `points` unchanged — the walk cannot step less than one
    ///     pixel, so there would be nothing to drop.
    public static func decimate(_ points: [PixelPoint], minSpacing: Double) -> [PixelPoint] {
        guard minSpacing > 1, points.count > 2 else { return points }
        let least = minSpacing * minSpacing
        var kept: [PixelPoint] = [points[0]]
        kept.reserveCapacity(points.count)
        for point in points.dropFirst() {
            let last = kept[kept.count - 1]
            let dx = point.x - last.x, dy = point.y - last.y
            if dx * dx + dy * dy >= least { kept.append(point) }
        }
        if let end = points.last, kept[kept.count - 1] != end { kept.append(end) }
        return kept
    }
}
