import AppKit

/// The interface's palette, radii and spacing — one place, named by *what the
/// colour is for*, never by what it looks like. See `美学设计.md` §4.
///
/// Every colour here is **dynamic**: it resolves against the appearance it is
/// drawn under, light or dark. The before state had two ways of breaking that —
/// fixed `calibratedWhite` values (the sidebar, unreadable in dark mode) and a
/// dynamic colour captured into a `CGColor` once at build time (the toolbar and
/// the info bar, stuck at whatever the system started in). Both are the same
/// mistake — deciding the colour before knowing the appearance — and the rule
/// that prevents it is structural: tokens are evaluated at draw time, and
/// nothing in the interface holds a resolved colour.
enum Design {

    /// Builds a colour that answers differently under dark and light
    /// appearances. The two answers are given separately because dark mode is
    /// not light mode inverted — a header band, for instance, is a step
    /// *darker* than its card in light and a step *lighter* in dark.
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    // MARK: - The data panel

    /// The grey field the cards sit on. Light keeps the accepted 0.937; dark is
    /// a touch *lighter* than the card bodies on it, which is how dark-mode
    /// layering reads — content wells sink, chrome floats.
    static let panelField = adaptive(NSColor(calibratedWhite: 0.937, alpha: 1),
                                     NSColor(calibratedWhite: 0.165, alpha: 1))

    /// A card's body: the system's own content-well colour, already dynamic.
    static var cardBody: NSColor { .textBackgroundColor }

    /// A card's title band. A step darker than the body in light (0.886 kept);
    /// a step *lighter* in dark, because "one level up" has no darker direction
    /// left to go.
    static let cardHeader = adaptive(NSColor(calibratedWhite: 0.886, alpha: 1),
                                     NSColor(calibratedWhite: 0.24, alpha: 1))

    /// A card's outline. Deliberately not `separatorColor`: that is tuned for
    /// hairlines on white and measures within a point of the panel itself, so
    /// against this field the cards would have no edge at all.
    static let cardBorder = adaptive(NSColor(calibratedWhite: 0.78, alpha: 1),
                                     NSColor(calibratedWhite: 0.38, alpha: 1))

    /// The Excel grid between table rows and columns. Three steps darker than
    /// the card body in light; the same structural role in dark.
    static let gridLine = adaptive(NSColor(calibratedWhite: 0.82, alpha: 1),
                                   NSColor(calibratedWhite: 0.30, alpha: 1))

    // MARK: - Chrome

    /// Toolbar and info bar background: the system's window colour, dynamic.
    /// Used at draw time — never captured into a `CGColor` ahead of it.
    static var chrome: NSColor { .windowBackgroundColor }

    /// One-point rules between chrome and content. Dynamic, and fine for
    /// boundaries (unlike card outlines, which need more presence — see
    /// `cardBorder`).
    static var hairline: NSColor { .separatorColor }

    // MARK: - Shape

    /// Corner radius of a card. The macOS 26 container language is rounded;
    /// the square 1pt boxes this replaces read as a decade older.
    static let cardRadius: CGFloat = 8

    /// The spacing grid: every gap in the interface comes from this family
    /// (4, 8, 12, 16) and nothing invents a new one.
    static let spacing: CGFloat = 8
}
