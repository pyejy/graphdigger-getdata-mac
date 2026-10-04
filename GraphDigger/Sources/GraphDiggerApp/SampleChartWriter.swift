import AppKit
import GDCore
import ImageIO
import UniformTypeIdentifiers

/// Writes a `BitmapBuffer` out as a PNG. Used by `--make-sample`.
enum SampleChartWriter {

    /// Writes a chart to `path`. With `multi` the file carries three differently
    /// coloured curves, which is what the multi-curve workflow needs to be tried
    /// on — a single-curve sample cannot show per-curve colour picking at all.
    static func write(to path: String, multi: Bool = false) {
        if multi {
            writeMulti(to: path)
            return
        }
        // A logistic curve on linear axes plus a second, log-scale chart give a
        // new user something that exercises both code paths.
        let chart = SyntheticChart.render()
        guard let cgImage = makeCGImage(from: chart.buffer) else {
            FileHandle.standardError.write(Data("error: could not build image\n".utf8))
            exit(1)
        }

        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            FileHandle.standardError.write(Data("error: cannot write to \(path)\n".utf8))
            exit(1)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            FileHandle.standardError.write(Data("error: PNG encoding failed\n".utf8))
            exit(1)
        }

        let map = chart.calibration
        print("Wrote \(path)  (\(chart.buffer.width)x\(chart.buffer.height))")
        print("Ground truth for calibration — click these four pixels and enter the values:")
        print("  X min  pixel (\(chart.axisX0), \(chart.axisY0))  ->  \(map.x.valueMin)")
        print("  X max  pixel (\(chart.axisX1), \(chart.axisY0))  ->  \(map.x.valueMax)")
        print("  Y min  pixel (\(chart.axisX0), \(chart.axisY0))  ->  \(map.y.valueMin)")
        print("  Y max  pixel (\(chart.axisX0), \(chart.axisY1))  ->  \(map.y.valueMax)")
        print("Curve colour: R\(chart.lineColor.r) G\(chart.lineColor.g) B\(chart.lineColor.b)")
    }

    private static func writeMulti(to path: String) {
        let chart = SyntheticChart.renderMulti()
        guard let cgImage = makeCGImage(from: chart.buffer),
              write(cgImage, to: path) else {
            FileHandle.standardError.write(Data("error: could not build image\n".utf8))
            exit(1)
        }

        let map = chart.calibration
        print("Wrote \(path)  (\(chart.buffer.width)x\(chart.buffer.height))  — \(chart.series.count) 条曲线")
        print("Ground truth for calibration — click these three pixels and enter the values:")
        print("  origin   pixel (\(chart.axisX0), \(chart.axisY0))  ->  (\(map.x.valueMin), \(map.y.valueMin))")
        print("  X end    pixel (\(chart.axisX1), \(chart.axisY0))  ->  \(map.x.valueMax)")
        print("  Y end    pixel (\(chart.axisX0), \(chart.axisY1))  ->  \(map.y.valueMax)")
        for (index, color) in chart.lineColors.enumerated() {
            print("Curve \(index + 1) colour: R\(color.r) G\(color.g) B\(color.b)")
        }
        print("Background: R\(chart.backgroundColor.r) G\(chart.backgroundColor.g) B\(chart.backgroundColor.b)"
              + "  (会自动检测,无需点取)")
    }

    /// Writes a CGImage out as PNG. Shared by both sample writers.
    @discardableResult
    private static func write(_ image: CGImage, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// CoreGraphics cannot build a 24-bits-per-pixel image, so the packed RGB
    /// buffer is widened to RGBX before handing it over.
    static func makeCGImage(from buffer: BitmapBuffer) -> CGImage? {
        let pixelCount = buffer.width * buffer.height
        var rgba = [UInt8](repeating: 255, count: pixelCount * 4)
        for i in 0..<pixelCount {
            rgba[i * 4] = buffer.pixels[i * 3]
            rgba[i * 4 + 1] = buffer.pixels[i * 3 + 1]
            rgba[i * 4 + 2] = buffer.pixels[i * 3 + 2]
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: buffer.width,
                       height: buffer.height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: buffer.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
