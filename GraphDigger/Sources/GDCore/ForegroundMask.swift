import Foundation

/// Boolean foreground mask over an image, plus the metadata the digitizers need.
///
/// Built once per (image, colours, tolerance) triple and reused by every
/// extraction pass, which is what keeps interactive re-digitising cheap.
public struct ForegroundMask: Sendable {
    public let width: Int
    public let height: Int
    /// Row-major, `width * height` entries. `true` = belongs to the curve.
    public var bits: [Bool]

    public init(width: Int, height: Int, bits: [Bool]) {
        precondition(bits.count == width * height, "mask size mismatch")
        self.width = width
        self.height = height
        self.bits = bits
    }

    @inlinable
    public func isForeground(x: Int, y: Int) -> Bool {
        bits[y * width + x]
    }

    public var foregroundCount: Int { bits.lazy.filter { $0 }.count }

    /// How far a pixel's *hue* may sit from the curve's and still count as the
    /// same ink, in degrees. `180` turns the test off.
    public static let defaultHueTolerance: Double = 60

    /// Chroma magnitude — how far a colour sits from grey — below which that
    /// colour has no usable hue.
    ///
    /// White, black and every grey between have a chroma of exactly 0, so
    /// "which way does it point" has no answer for them and a comparison would
    /// be an accident of rounding. 12 is low enough to keep a faintly tinted
    /// curve and high enough to leave a neutral background out of it.
    ///
    /// The two sides of the hue gate use this differently, and deliberately. A
    /// *line* below the floor has nothing to compare against, so the gate stands
    /// down and the older two gates decide. A *pixel* below it is not ink of a
    /// coloured line at all — see `build`.
    static let chromaFloor: Double = 12

    /// Weighted-RGB euclidean distance, the classic 2:4:3 approximation of
    /// perceived luminance. Using it (rather than plain RGB distance) is what
    /// makes the picker forgiving on anti-aliased strokes.
    ///
    /// Three gates, applied in this order:
    ///
    /// 1. **Distance** — within `tolerance` of the curve colour.
    /// 2. **Background** — nearer the curve colour than the background, when a
    ///    background is supplied. A nearest-colour classification rather than a
    ///    second fixed distance, because a fixed pair cannot separate a pale
    ///    curve from a pale background: a colour like RGB(200,205,215) on white
    ///    is 43 units from the background and 0 from the curve, so any two
    ///    thresholds either admit the whole plot or discard the curve with it.
    ///    What matters is which of the two the pixel resembles — a scale-free
    ///    question. `backgroundTolerance` remains for callers who want the extra
    ///    explicit gate; by default only the comparison applies.
    /// 3. **Hue** — carrying a hue that points the same way as the curve's. A
    ///    line with no hue of its own stands the gate down; a *pixel* with no
    ///    hue is background, not ink. See `defaultHueTolerance`.
    ///
    /// The third gate is not a refinement of the first two; it catches a case
    /// neither of them can see. The weighted distance *compresses* chromatic
    /// differences — the weight vector `(2,4,3)` is itself normalised away, so a
    /// difference along it is reported at full size while one across it is
    /// reported at up to 2.4× less — and the default tolerance of 60 therefore
    /// admits colours up to a plain-RGB distance of ~145. Measured on a real
    /// figure, a green curve (103,186,103) and an orange one (255,164,84) are
    /// **59.7** apart under this metric and **154.8** apart in plain RGB: the
    /// distance gate passes the orange stroke whole, and the background gate
    /// passes it too, because orange is 59.7 from the green curve and 115.9 from
    /// the white page — genuinely *nearer the curve than the background*. Both
    /// gates answer "yes", and the extraction mixes the two curves.
    ///
    /// Hue is what differs, and hue is also the one property anti-aliasing
    /// leaves alone: a stroke pixel is `(1-t)·curve + t·background`, so while
    /// the background is neutral the blend slides from the curve colour towards
    /// grey **without changing direction**. Every edge pixel of the curve
    /// therefore points exactly the way the curve does, at any opacity, however
    /// faint — while a differently coloured stroke points elsewhere. On the
    /// figure above the gate removes 17 668 orange pixels and 19 376 blue ones
    /// from the green mask and keeps all 55 597 green ones.
    public static func build(from buffer: BitmapBuffer,
                             lineColor: RGB8,
                             tolerance: Double,
                             backgroundColor: RGB8? = nil,
                             backgroundTolerance: Double? = nil,
                             hueTolerance: Double = ForegroundMask.defaultHueTolerance) -> ForegroundMask {
        let n = buffer.width * buffer.height
        var bits = [Bool](repeating: false, count: n)

        let lr = Double(lineColor.r), lg = Double(lineColor.g), lb = Double(lineColor.b)
        let lineToleranceSquared = tolerance * tolerance

        let bg = backgroundColor.map {
            (Double($0.r), Double($0.g), Double($0.b))
        }
        let bgToleranceSquared = backgroundTolerance.map { $0 * $0 }

        // The line's hue, held as the vector from grey: its length says how
        // colourful the line is, its direction *is* the hue. Squared lengths are
        // carried alongside because nothing below ever needs a square root.
        let lineChroma = chroma(lr, lg, lb)
        let lineChromaSquared = lengthSquared(lineChroma)
        // A hue test against a grey line would be a test about nothing, so the
        // gate stands down when the line has no hue to compare against.
        let hueGateIsUsable = hueTolerance < 180
            && lineChromaSquared >= chromaFloor * chromaFloor
        let hueLimit = cos(hueTolerance * .pi / 180)
        let hueLimitSquared = hueLimit * hueLimit
        let chromaFloorSquared = chromaFloor * chromaFloor

        buffer.pixels.withUnsafeBufferPointer { px in
            bits.withUnsafeMutableBufferPointer { out in
                for i in 0..<n {
                    let base = i * 3
                    let r = Double(px[base])
                    let g = Double(px[base + 1])
                    let b = Double(px[base + 2])

                    let toLine = weightedSquare(r - lr, g - lg, b - lb)
                    if toLine > lineToleranceSquared {
                        continue
                    }
                    if let bg {
                        // Nearer the background than the curve: not this curve.
                        if toLine >= weightedSquare(r - bg.0, g - bg.1, b - bg.2) {
                            continue
                        }
                        if let bgToleranceSquared, bgToleranceSquared > 0 {
                            if weightedSquare(r - bg.0, g - bg.1, b - bg.2) <= bgToleranceSquared {
                                continue
                            }
                        }
                    }

                    // The hue gate. It stands down only when the *line* has no hue
                    // of its own, which is when there is nothing to compare
                    // against; a pixel with none is not ink of a coloured line.
                    if hueGateIsUsable {
                        let pixelChroma = chroma(r, g, b)
                        let pixelChromaSquared = lengthSquared(pixelChroma)
                        // A stroke fades towards the background by *losing* chroma
                        // — the blend is `t·ink + (1-t)·background`, so a pixel
                        // carries `t` of the ink's chroma — and never by turning
                        // grey. A pixel with no chroma at all is background that
                        // happens to resemble the line, and it has to go: under
                        // this metric a mid-grey really is nearer a mid-green than
                        // the white page is, so the anti-aliased rim of a black
                        // axis line lands inside a green curve's mask otherwise.
                        if pixelChromaSquared < chromaFloorSquared {
                            continue
                        }
                        let dot = lineChroma.0 * pixelChroma.0
                            + lineChroma.1 * pixelChroma.1
                            + lineChroma.2 * pixelChroma.2
                        // Keeping the pixel means `cos(angle) >= hueLimit`, i.e.
                        // `dot >= hueLimit·|line|·|pixel|` — both sides positive,
                        // so squaring is safe and saves a square root per pixel.
                        // The `dot <= 0` arm is needed separately: squaring would
                        // fold the hues more than 90° away back onto the near side
                        // and admit them.
                        if dot <= 0
                            || dot * dot < hueLimitSquared * lineChromaSquared * pixelChromaSquared {
                            continue
                        }
                    }
                    out[i] = true
                }
            }
        }
        return ForegroundMask(width: buffer.width, height: buffer.height, bits: bits)
    }

    /// Squared weighted distance. The weight vector `(2,4,3)` is normalised by
    /// its own length, so a difference running *along* `(2,4,3)` — a grey step,
    /// where all three channels move together — is reported at its true size,
    /// while one running across it comes out up to 2.4× smaller. That is why the
    /// hue gate above is load-bearing rather than decorative.
    @inline(__always)
    private static func weightedSquare(_ dr: Double, _ dg: Double, _ db: Double) -> Double {
        let wr = dr * 2.0, wg = dg * 4.0, wb = db * 3.0
        return (wr * wr + wg * wg + wb * wb) / 29.0
    }

    /// The colour as seen from the grey axis: each channel minus the mean.
    ///
    /// Blending towards any neutral colour scales this vector and leaves its
    /// direction untouched, which is the property the hue gate rests on.
    @inline(__always)
    private static func chroma(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mean = (r + g + b) / 3
        return (r - mean, g - mean, b - mean)
    }

    @inline(__always)
    private static func lengthSquared(_ v: (Double, Double, Double)) -> Double {
        v.0 * v.0 + v.1 * v.1 + v.2 * v.2
    }
}
