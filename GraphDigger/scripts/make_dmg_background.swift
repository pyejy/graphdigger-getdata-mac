// 生成安装包(dmg)的窗口背景图。
//
// 与 `make_icon.swift` 同一个路子:**图是代码画出来的**,不是塞进来的二进制资源 ——
// 设计改了改数字重跑即可,没有"母版丢了就改不动"的问题。所以这里逐尺寸原生绘制
// (不缩放),并按 2× 出图 + 144 dpi,让 Retina 屏上不糊。
//
// 用法:`swift scripts/make_dmg_background.swift <输出.png> [宽 高]`
//
// 布局与 `dmg_settings.py` 里的图标位置是一套:窗口 640×400 点,两个图标在
// (170, 190) 与 (470, 190)。所以箭头画在两者之间,y 与图标中心对齐 ——
// 两边任何一处改了,另一处必须跟着改,否则箭头会指歪(数值就写在这两处注释里)。

import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("用法: make_dmg_background.swift <输出.png> [宽 高]\n".data(using: .utf8)!)
    exit(2)
}
let outputPath = arguments[1]
let width = arguments.count >= 3 ? (Double(arguments[2]) ?? 640) : 640
let height = arguments.count >= 4 ? (Double(arguments[3]) ?? 400) : 400

let scale = 2.0
let pixelsWide = Int(width * scale)
let pixelsHigh = Int(height * scale)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    exit(1)
}
// 按 2× 出图,标 144 dpi,Finder 才会把它当成 width×height 点来铺。
rep.size = NSSize(width: width, height: height)

// **不要再手动缩放**:`rep.size` 设成点尺寸(640×400)而像素是 1280×800,
// AppKit 自己就把点映射到 2× 像素了 —— 再 `scaleBy(2)` 等于画到 4×,
// 内容会整块跑出画面(踩过:箭头和标题全都不见了)。
guard let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.current = context

let bounds = NSRect(x: 0, y: 0, width: width, height: height)
NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
bounds.fill()

/// Finder 传下来的坐标原点在**左上**,而 AppKit 在左下 —— 这里翻一次,
/// 后面所有位置都能按 Finder 的说法写(与 dmg_settings.py 一致)。
func flipped(_ y: CGFloat) -> CGFloat { height - y }

func draw(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight,
          color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    let measured = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: point.x - measured.width / 2, y: point.y), withAttributes: attributes)
}

// 标题(顶部)
draw("把 GraphDigger 拖进「应用程序」",
     at: NSPoint(x: width / 2, y: flipped(58)), size: 15, weight: .medium,
     color: NSColor(calibratedWhite: 0.20, alpha: 1))

// 箭头:两个图标之间,与图标中心同高(图标中心 y = 190)
let arrow = NSBezierPath()
let arrowY = flipped(190)
arrow.move(to: NSPoint(x: 268, y: arrowY))
arrow.line(to: NSPoint(x: 372, y: arrowY))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
NSColor(calibratedWhite: 0.62, alpha: 1).setStroke()
arrow.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 356, y: arrowY + 9))
head.line(to: NSPoint(x: 374, y: arrowY))
head.line(to: NSPoint(x: 356, y: arrowY - 9))
head.lineWidth = 3
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// 底部说明。这一行是有用的,不是装饰:应用只做了 ad-hoc 签名,第一次打开会被
// Gatekeeper 拦住,右键打开是唯一的出路 —— 让人在装的时候就看见,而不是撞上。
draw("首次打开请右键点图标 ▸ 打开(未做开发者签名)",
     at: NSPoint(x: width / 2, y: flipped(352)), size: 11, weight: .regular,
     color: NSColor(calibratedWhite: 0.45, alpha: 1))

guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? data.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) (\(pixelsWide)×\(pixelsHigh) px @ \(Int(scale))×)")
