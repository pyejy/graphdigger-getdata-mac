import Foundation

/// A tick position on a calibrated axis: the chart value and where it lands in
/// the image.
public struct AxisTick: Equatable, Sendable {
    public let value: Double
    public let pixel: Double
    /// Major ticks carry a label; minor ticks are drawn shorter.
    public let isMajor: Bool

    public init(value: Double, pixel: Double, isMajor: Bool = true) {
        self.value = value
        self.pixel = pixel
        self.isMajor = isMajor
    }
}

public extension AxisCalibration {

    /// "Nice" tick values spanning the given pixel range.
    ///
    /// Drawing these over the loaded image is how a user verifies a calibration:
    /// if the ticks do not land on the chart's own graticule, the reference
    /// points or values were entered wrong — something a bare number readout
    /// cannot reveal.
    ///
    /// Linear axes step by 1/2/5 × 10ⁿ; log axes step by decades, subdividing
    /// into 1-2-5 when only a few decades are visible.
    func ticks(overPixelRange pixelRange: ClosedRange<Double>,
               targetCount: Int = 8) -> [AxisTick] {
        guard pixelMax != pixelMin, targetCount > 0 else { return [] }
        if isLogarithmic && Swift.min(valueMin, valueMax) <= 0 { return [] }

        let rawValues = [try? value(atPixel: pixelRange.lowerBound),
                         try? value(atPixel: pixelRange.upperBound)].compactMap { $0 }
        guard rawValues.count == 2 else { return [] }
        let lowValue = Swift.min(rawValues[0], rawValues[1])
        let highValue = Swift.max(rawValues[0], rawValues[1])
        guard highValue > lowValue, lowValue.isFinite, highValue.isFinite else { return [] }

        return isLogarithmic
            ? logTicks(lowValue: lowValue, highValue: highValue)
            : linearTicks(lowValue: lowValue, highValue: highValue, targetCount: targetCount)
    }

    private func makeTick(_ value: Double) -> AxisTick? {
        guard let pixel = try? pixel(atValue: value), pixel.isFinite else { return nil }
        return AxisTick(value: value, pixel: pixel)
    }

    private func linearTicks(lowValue: Double, highValue: Double,
                             targetCount: Int) -> [AxisTick] {
        let step = Self.niceStep((highValue - lowValue) / Double(targetCount))
        guard step > 0, step.isFinite else { return [] }

        var ticks: [AxisTick] = []
        var value = (lowValue / step).rounded(.up) * step
        // A cap independent of the step keeps a pathological range from
        // generating an unbounded list.
        var guardCount = 0
        while value <= highValue * (1 + 1e-9), guardCount < 1_000 {
            if let tick = makeTick(value) { ticks.append(tick) }
            value += step
            guardCount += 1
        }
        return ticks
    }

    private func logTicks(lowValue: Double, highValue: Double) -> [AxisTick] {
        let lowExponent = Int(floor(log10(lowValue)))
        let highExponent = Int(ceil(log10(highValue)))
        let decades = highExponent - lowExponent

        // Few decades: subdivide so there is something to look at. Many: one
        // tick per decade, plus the 1-2-5 chain when there is room.
        let mantissas: [Double] = decades <= 3 ? [1, 2, 3, 4, 5, 6, 7, 8, 9] : [1, 2, 5]

        var ticks: [AxisTick] = []
        for exponent in lowExponent...highExponent {
            for mantissa in mantissas {
                let value = mantissa * pow(10.0, Double(exponent))
                guard value >= lowValue * (1 - 1e-9), value <= highValue * (1 + 1e-9) else { continue }
                if let tick = makeTick(value) {
                    ticks.append(AxisTick(value: value, pixel: tick.pixel,
                                          isMajor: mantissa == 1))
                }
            }
        }
        return ticks
    }

    /// Rounds a step up to the nearest 1, 2 or 5 times a power of ten.
    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 0 }
        let exponent = floor(log10(raw))
        let magnitude = pow(10.0, exponent)
        let normalized = raw / magnitude
        let nice: Double
        switch normalized {
        case ..<1.5: nice = 1
        case ..<3.5: nice = 2
        case ..<7.5: nice = 5
        default:     nice = 10
        }
        return nice * magnitude
    }
}
