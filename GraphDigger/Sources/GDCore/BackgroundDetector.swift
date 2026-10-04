import Foundation

/// Works out what the image's background is, so the user does not have to click
/// it before extracting each curve.
public enum BackgroundDetector {

    /// The most common colour in the border band of the image.
    ///
    /// Science charts are drawn on a flat background, and the frame of the image
    /// is nearly always that background — so sampling the border and taking the
    /// mode is both accurate and immune to a large plot area full of ink.
    ///
    /// Colours are quantised into 8×8×8 buckets before counting: a scanned or
    /// JPEG-compressed chart has slight per-pixel variation, and exact-value
    /// counting would find no majority at all. The bucket's true mean colour is
    /// returned, not the bucket centre, so the sampled value stays close to what
    /// the picker would have produced.
    public static func detect(in buffer: BitmapBuffer, borderFraction: Double = 0.02) -> RGB8? {
        let w = buffer.width, h = buffer.height
        guard w > 0, h > 0 else { return nil }

        let band = max(1, Int(Double(min(w, h)) * borderFraction))

        var buckets: [Int: (count: Int, sumR: Int, sumG: Int, sumB: Int)] = [:]

        @inline(__always)
        func sample(_ x: Int, _ y: Int) {
            let c = buffer.color(atX: x, y: y)
            let key = (Int(c.r) >> 3) << 12 | (Int(c.g) >> 3) << 6 | (Int(c.b) >> 3)
            var entry = buckets[key] ?? (0, 0, 0, 0)
            entry.count += 1
            entry.sumR += Int(c.r)
            entry.sumG += Int(c.g)
            entry.sumB += Int(c.b)
            buckets[key] = entry
        }

        for y in 0..<band {
            for x in 0..<w {
                sample(x, y)                    // top band
                sample(x, h - 1 - y)            // bottom band
            }
        }
        for x in 0..<band {
            for y in band..<(h - band) {
                sample(x, y)                    // left band
                sample(w - 1 - x, y)            // right band
            }
        }

        guard let best = buckets.max(by: { $0.value.count < $1.value.count })?.value,
              best.count > 0 else { return nil }

        return RGB8(r: UInt8(clamping: best.sumR / best.count),
                    g: UInt8(clamping: best.sumG / best.count),
                    b: UInt8(clamping: best.sumB / best.count))
    }

    /// Convenience for a raw pixel array, matching `ForegroundMask.build`.
    public static func detect(pixels: [UInt8], width: Int, height: Int) -> RGB8? {
        detect(in: BitmapBuffer(width: width, height: height, pixels: pixels))
    }
}
