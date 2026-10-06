import Foundation

/// One axis of a **data-space** plot: where a chart value sits across the band,
/// and which values deserve a label.
///
/// `AxisTicks` answers the opposite question — given a pixel range on the
/// scanned image, which chart values land there — because it exists to check a
/// calibration against the picture. This is for drawing the extracted data on
/// its own, where the picture is gone and the axis is the thing being chosen:
/// the range comes from the data, and the labels have to be round numbers.
///
/// Kept in `GDCore` rather than in the view for the usual reason: the interesting
/// part is arithmetic (what "a round number near 0.037" means, how a log axis
/// stretches), and arithmetic is what a unit test can pin down. The view is left
/// with nothing but rectangles.
public struct PlotAxis: Equatable, Sendable {

    /// Whether the values are stretched logarithmically — taken from the
    /// calibration, so the plot agrees with the axis the user calibrated against.
    public let isLogarithmic: Bool
    /// The value at fraction 0, and at fraction 1. `low` may exceed `high` for a
    /// reversed axis, which is what a decreasing Y axis produces.
    public let low: Double
    public let high: Double
    /// Label-worthy values inside the range, ascending.
    public let ticks: [Double]

    /// Nil for a range that cannot be drawn: nothing finite, or a log axis fed a
    /// non-positive end.
    public init?(low: Double, high: Double, isLogarithmic: Bool = false, targetCount: Int = 6) {
        guard low.isFinite, high.isFinite, low != high else { return nil }
        if isLogarithmic && (low <= 0 || high <= 0) { return nil }
        self.isLogarithmic = isLogarithmic
        self.low = low
        self.high = high
        self.ticks = Self.tickValues(from: low, to: high,
                                     isLogarithmic: isLogarithmic,
                                     targetCount: targetCount)
    }

    /// 0 at `low`, 1 at `high`; log axes place by the exponent. Nil when the
    /// value cannot be placed at all — a log axis and a value at or below zero.
    ///
    /// Deliberately not clamped: a caller that wants to know a point fell outside
    /// the range can ask, and the view clips on its side.
    public func fraction(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        if isLogarithmic {
            guard value > 0, low > 0, high > 0 else { return nil }
            let span = log10(high) - log10(low)
            guard span != 0 else { return nil }
            return (log10(value) - log10(low)) / span
        }
        return (value - low) / (high - low)
    }

    /// A range that holds every value, with ends on round numbers so the labels
    /// are readable.
    ///
    /// Snapping *is* the padding, deliberately. Adding a margin first and then
    /// rounding outwards double-counts it: data spanning 0…1 comes back as
    /// −0.2…1.2, and the plot spends a fifth of its width on empty space that no
    /// number on the axis explains. Rounding the ends outward leaves a margin
    /// that is at most one tick step, which is exactly the margin a reader
    /// expects.
    public static func covering(_ values: [Double],
                                isLogarithmic: Bool = false,
                                targetCount: Int = 6) -> (low: Double, high: Double)? {
        let finite = values.filter { $0.isFinite }
        guard !finite.isEmpty else { return nil }

        if isLogarithmic {
            let positive = finite.filter { $0 > 0 }
            guard !positive.isEmpty else { return nil }
            let lowExponent = log10(positive.min()!), highExponent = log10(positive.max()!)
            guard highExponent > lowExponent else {
                // One value, or a run of equal ones: a decade either side rather
                // than a range of no width.
                return (pow(10, lowExponent - 1), pow(10, highExponent + 1))
            }
            // Decades are the only round numbers on a log axis, so that is what
            // the ends snap to.
            return (pow(10, floor(lowExponent)), pow(10, ceil(highExponent)))
        }

        let least = finite.min()!, most = finite.max()!
        guard most > least else {
            // Everything equal: open a window rather than dividing by zero.
            let half = least == 0 ? 0.5 : abs(least) * 0.1
            return (least - half, least + half)
        }
        let span = most - least
        let step = AxisCalibration.niceStep(span / Double(max(1, targetCount)))
        guard step > 0, step.isFinite else { return (least, most) }
        let low = (least / step).rounded(.down) * step
        let high = (most / step).rounded(.up) * step
        guard low < high else { return (least - span / 2, most + span / 2) }
        return (low, high)
    }

    /// Round values between the ends, ascending.
    private static func tickValues(from low: Double, to high: Double,
                                   isLogarithmic: Bool, targetCount: Int) -> [Double] {
        let least = min(low, high), most = max(low, high)

        if isLogarithmic {
            guard least > 0 else { return [] }
            // Density follows the span actually drawn, not the exponents the ends
            // happen to round to: 0.5…20 covers 1.6 decades and can carry the
            // 1-2-5 chain, while 1…1000 covers three and cannot.
            let logSpan = log10(most) - log10(least)
            let mantissas: [Double] = logSpan <= 2 ? [1, 2, 5] : [1]
            let lowExponent = Int(floor(log10(least) - 1e-9))
            let highExponent = Int(ceil(log10(most) + 1e-9))
            var values: [Double] = []
            for exponent in lowExponent...max(lowExponent, highExponent) {
                for mantissa in mantissas {
                    let value = mantissa * pow(10.0, Double(exponent))
                    if value >= least * (1 - 1e-9), value <= most * (1 + 1e-9) { values.append(value) }
                }
            }
            return values
        }

        let step = AxisCalibration.niceStep((most - least) / Double(max(1, targetCount)))
        guard step > 0, step.isFinite else { return [] }
        var values: [Double] = []
        var value = (least / step).rounded(.up) * step
        // A cap independent of the step keeps a pathological range bounded.
        var guardCount = 0
        while value <= most * (1 + 1e-9), guardCount < 1_000 {
            values.append(value)
            value += step
            guardCount += 1
        }
        return values
    }
}
