import AppKit

/// 「关于 GraphDigger」面板。
///
/// 自己画而不是用系统的 `orderFrontStandardAboutPanel`:系统面板只留了一行
/// 「Credits」的位置给附加内容,两枚收款码要在那里并排摆好、还要跟着深浅外观走,
/// 靠一段富文本去凑排版是跟 AppKit 讨价还价。自己的窗口里,布局、颜色、关闭
/// 行为都是明写的,也能被自检渲染出来验(系统面板验不了)。
///
/// 内容是四层:应用图标 → 名字与版本 → 作者 → 赞助收款码。**颜色一律用动态颜色**
/// (Design 的铁律):这个窗口会同时出现在浅色和深色下,任何固化成 CGColor 的取值
/// 都会在其中一种外观里破洞。
enum AboutWindow {

    /// 作者。写在这里是为了让自检能断言它 —— 一个字的签名不该靠肉眼核对。
    static let authorName = "徐志勇"

    private static var window: NSWindow?

    /// 版本号:包里有 Info.plist 就读它,否则说明是在裸二进制里跑(开发期),
    /// 如实说「开发版」而不是编一个号 —— 版本号只有一处来源(`build_universal.sh`)。
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "开发版"
    }

    /// 收款码。包里有图就用图;裸二进制里没有资源,返回 nil 由调用方画占位。
    static func paymentImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = makeContentView()
        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "关于 GraphDigger"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.contentView = content
        panel.center()
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 内容

    /// 面板内容。**不是 private**:自检要把它搭出来,断言作者名与版本真的
    /// 出现在某一行文字上(只断言常量等于常量等于没断言)。
    static func makeContentView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 10

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        root.addArrangedSubview(icon)
        root.setCustomSpacing(14, after: icon)

        let name = label("GraphDigger", size: 19, weight: .semibold, color: .labelColor)
        root.addArrangedSubview(name)
        root.addArrangedSubview(label("版本 \(version)", size: 12, color: .secondaryLabelColor))
        root.addArrangedSubview(label("作者 \(authorName)", size: 12, color: .secondaryLabelColor))
        root.setCustomSpacing(18, after: root.arrangedSubviews.last!)

        root.addArrangedSubview(separator(width: 320))
        root.setCustomSpacing(14, after: root.arrangedSubviews.last!)

        root.addArrangedSubview(label("赞助支持", size: 14, weight: .medium, color: .labelColor))
        root.addArrangedSubview(label("这个工具帮到了你的话,可以扫码支持一下",
                                      size: 11, color: .secondaryLabelColor))
        root.setCustomSpacing(12, after: root.arrangedSubviews.last!)

        let codes = NSStackView(views: [
            paymentColumn(title: "微信支付", resource: "wechat-qr"),
            paymentColumn(title: "支付宝", resource: "alipay-qr"),
        ])
        codes.orientation = .horizontal
        codes.spacing = 24
        codes.alignment = .top
        root.addArrangedSubview(codes)

        // 四周留白,并给窗口一个最小宽度 —— 内容自己算出来的宽度会让两枚码贴边。
        root.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 22, right: 28)
        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
        ])
        return container
    }

    private static func paymentColumn(title: String, resource: String) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6

        let frame = CardView()
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.widthAnchor.constraint(equalToConstant: 148).isActive = true
        frame.heightAnchor.constraint(equalToConstant: 148).isActive = true

        if let image = paymentImage(named: resource) {
            let view = NSImageView()
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            view.translatesAutoresizingMaskIntoConstraints = false
            frame.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: frame.topAnchor, constant: 8),
                view.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -8),
                view.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 8),
                view.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -8),
            ])
        } else {
            // 开发版(裸二进制)没有资源:画个占位并说明,而不是留一块空白让人以为坏了。
            let placeholder = label("收款码在打包后可见", size: 10, color: .secondaryLabelColor)
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            frame.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
                placeholder.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
            ])
        }
        column.addArrangedSubview(frame)
        column.addArrangedSubview(label(title, size: 11, color: .secondaryLabelColor))
        return column
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                              color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = .center
        return field
    }

    private static func separator(width: CGFloat) -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: width).isActive = true
        return line
    }
}

/// 收款码的白色卡片。
///
/// 为什么需要它:二维码四周的**静区必须是白的**,而窗口底色在深色外观下是深的 ——
/// 直接贴上去等于把码的留白边吃掉,扫不出来。
///
/// 为什么是自绘而不是 `layer.backgroundColor`:项目有一条铁律 —— 颜色在 draw 时
/// 按当前外观解析,不把 `NSColor` 固化成 `CGColor` 存起来(layer 的颜色是快照,
/// 外观切换时不会重取,那正是深色模式破洞的来源)。这里白色两种外观下都不变,
/// 但规矩照旧:同一处写法,以后谁把它改成动态色也不会踩坑。
private final class CardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}
