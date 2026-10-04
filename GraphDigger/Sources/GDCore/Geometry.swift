import Foundation

/// A point in the source image's pixel space. Sub-pixel precision throughout.
public struct PixelPoint: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// A point in the chart's data space (the values the axes show).
public struct DataPoint: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// 8-bit per channel colour, the working colour type for picking and masking.
public struct RGB8: Equatable, Hashable, Codable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// An axis-aligned integer rectangle in pixel space.
public struct PixelRect: Equatable, Sendable {
    public var x0: Int
    public var y0: Int
    public var x1: Int
    public var y1: Int
    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }
}

/// A decoded image held as packed RGB, 3 bytes per pixel, row-major.
///
/// Decoding happens once in the app layer (ImageIO); everything below this
/// type is pure arithmetic, which keeps GDCore free of AppKit.
public struct BitmapBuffer: Sendable {
    public let width: Int
    public let height: Int
    /// `width * height * 3` bytes: R, G, B per pixel.
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count >= width * height * 3, "pixel buffer too small")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    @inlinable
    public func color(atX x: Int, y: Int) -> RGB8 {
        let i = (y * width + x) * 3
        return RGB8(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2])
    }
}

public enum GeometryError: Error, Equatable {
    case degenerateAxis
    case logScaleRequiresPositiveValues
    case startNotOnForeground
}
