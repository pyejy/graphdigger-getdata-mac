import CoreGraphics
import Foundation

/// Maps between image pixel coordinates and view coordinates (zoom + pan).
///
/// Kept in GDCore, and free of AppKit, so the interaction maths can be unit
/// tested without a running application.
public struct ViewTransform: Equatable, Sendable {
    /// View points per image pixel. 1.0 means the image is shown at 1:1.
    public var scale: Double
    /// Where the image's origin (0, 0) sits in view coordinates.
    public var offset: CGPoint

    public init(scale: Double = 1, offset: CGPoint = .zero) {
        self.scale = scale
        self.offset = offset
    }

    public static let minimumScale = 0.02
    public static let maximumScale = 64.0

    public func viewPoint(fromImage p: PixelPoint) -> CGPoint {
        CGPoint(x: p.x * scale + Double(offset.x),
                y: p.y * scale + Double(offset.y))
    }

    public func imagePoint(fromView p: CGPoint) -> PixelPoint {
        PixelPoint(x: (Double(p.x) - Double(offset.x)) / scale,
                   y: (Double(p.y) - Double(offset.y)) / scale)
    }

    /// Scales the image to sit inside `viewSize` with a margin, and centres it.
    public mutating func fit(imageWidth: Int, imageHeight: Int,
                             viewWidth: Double, viewHeight: Double,
                             padding: Double = 20) {
        guard imageWidth > 0, imageHeight > 0, viewWidth > 0, viewHeight > 0 else { return }
        let availableW = max(viewWidth - padding * 2, 1)
        let availableH = max(viewHeight - padding * 2, 1)
        let fitted = min(availableW / Double(imageWidth), availableH / Double(imageHeight))
        scale = min(max(fitted, Self.minimumScale), Self.maximumScale)
        offset = CGPoint(
            x: (viewWidth - Double(imageWidth) * scale) / 2,
            y: (viewHeight - Double(imageHeight) * scale) / 2)
    }

    /// Zooms by `factor`, keeping the image point under `anchor` (a view
    /// coordinate) pinned in place — the behaviour expected when zooming with
    /// the cursor or a trackpad pinch.
    public mutating func zoom(by factor: Double, around anchor: CGPoint) {
        let newScale = min(max(scale * factor, Self.minimumScale), Self.maximumScale)
        guard newScale != scale else { return }
        let anchorImage = imagePoint(fromView: anchor)
        scale = newScale
        offset = CGPoint(x: Double(anchor.x) - anchorImage.x * scale,
                         y: Double(anchor.y) - anchorImage.y * scale)
    }

    public mutating func pan(by delta: CGPoint) {
        offset = CGPoint(x: Double(offset.x) + Double(delta.x),
                         y: Double(offset.y) + Double(delta.y))
    }
}
