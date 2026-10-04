import AppKit

/// Builds the window's view hierarchy and its constraints.
///
/// Extracted from `AppDelegate` so the layout can be exercised headlessly with
/// no window: a previous version used autoresizing masks that pinned the
/// toolbar by the wrong margin, which only showed up when going fullscreen —
/// the toolbar slid into the canvas, which is drawn on top, and the buttons
/// disappeared. Constraining it explicitly is what fixes that, and the selftest
/// resizes this exact layout to prove it stays put.
///
/// The frame reads as three bands and one column:
///
///     ┌───────────────────────────────┬──────────┐
///     │ toolbar                       │ 数据面板 │
///     ├───────────────────────────────┤ (full    │
///     │ info bar (step · status · sum)│  height) │
///     ├───────────────────────────────┤          │
///     │ canvas                        │          │
///     └───────────────────────────────┴──────────┘
///
/// The toolbar spans only the canvas column and the panel runs the full height,
/// so their top edges align: a strip of window background above the panel was
/// exactly the unclaimed-looking area the user objected to.
enum MainLayout {

    /// Height of the button row. One row, nothing else — the text lives in the
    /// info bar below.
    static let toolbarHeight: CGFloat = 52
    /// Height of the status strip under the toolbar. Two text rows plus padding.
    static let infoBarHeight: CGFloat = 52
    /// Width of the data panel. Fixed: it is a readout column, and letting it
    /// grow would eat the canvas that the actual work happens on.
    static let sidebarWidth: CGFloat = 272

    /// The narrowest the canvas column may be squeezed to — not the window's
    /// minimum width, which is this plus the panel. See
    /// `windowMinimumWidth(toolbarWidth:)`.
    static let minimumWindowWidth: CGFloat = 900

    /// The width of the narrowest screen the window has to fit on, in points.
    ///
    /// A 13-inch MacBook Air at its default scaled resolution gives 1440pt of
    /// usable width; that is the smallest canvas the app is expected to open in,
    /// and on the machine this was written for the *visible* frame is barely
    /// wider (1470pt, minus a 65pt menu bar). Everything that spends width — the
    /// toolbar row, the panel — has to leave `windowMinimumWidth(toolbarWidth:)`
    /// at or under this, or the window opens wider than the screen and the user
    /// cannot reach its edges. The selftest asserts exactly that, which is why
    /// this is a number and not a paragraph.
    static let narrowestScreenWidth: CGFloat = 1440

    /// The window width below which the layout breaks.
    ///
    /// The toolbar and the canvas share one column, so the window is the sum of
    /// that column and the panel — not the larger of the toolbar and some
    /// minimum, which is the shape this had. Kept here rather than in
    /// `AppDelegate` so the selftest can build the window's actual minimum and
    /// measure the row inside it; the check that used to guard this compared
    /// `minimumWindowWidth + sidebarWidth` against the toolbar and so passed for
    /// any toolbar up to 1172pt, whatever the real window did.
    static func windowMinimumWidth(toolbarWidth: CGFloat) -> CGFloat {
        max(toolbarWidth, minimumWindowWidth) + sidebarWidth
    }

    /// Adds the views to `container` and pins them: the toolbar across the top at
    /// a fixed height, the data panel down the right at a fixed width, and the
    /// canvas filling everything left over.
    static func install(container: NSView, toolbar: NSView, canvas: NSView,
                        sidebar: NSView? = nil,
                        infoBar: NSView? = nil,
                        toolbarHeight: CGFloat = MainLayout.toolbarHeight,
                        infoBarHeight: CGFloat = MainLayout.infoBarHeight,
                        sidebarWidth: CGFloat = MainLayout.sidebarWidth) {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)
        container.addSubview(canvas)

        var fullWidthBand = toolbar
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),
        ])

        if let infoBar {
            infoBar.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(infoBar)
            NSLayoutConstraint.activate([
                infoBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
                infoBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                infoBar.heightAnchor.constraint(equalToConstant: infoBarHeight),
                // The bar and the button row are the same column, so the bar's
                // trailing edge is what gives the toolbar its width.
                toolbar.trailingAnchor.constraint(equalTo: infoBar.trailingAnchor),

                canvas.topAnchor.constraint(equalTo: infoBar.bottomAnchor),
                canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            fullWidthBand = infoBar
        } else {
            NSLayoutConstraint.activate([
                canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
                canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        guard let sidebar else {
            NSLayoutConstraint.activate([
                toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                fullWidthBand.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            return
        }

        // The panel's edges come first, so the bands can hang off them: a
        // constraint between two subviews is only satisfiable once at least one
        // of them is pinned to the container itself.
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebar)
        NSLayoutConstraint.activate([
            // Top of the window, not below the toolbar: the panel is a work area
            // and should own its full column.
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth),
        ])

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fullWidthBand.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
        ])
    }
}
