import AppKit
import GDCore

/// Headless entry points, kept in `main.swift` so the app can be exercised from
/// a terminal without driving the GUI:
///
///     GraphDigger --make-sample out.png        one curve
///     GraphDigger --make-sample out.png --multi  three coloured curves
///     GraphDigger --selftest                   run the whole pipeline and report
///
/// `--selftest` matters because it exercises the shipping binary, not just the
/// test bundle: decode → mask → calibrate → digitise → export.
let arguments = CommandLine.arguments

// AppKit needs an NSApplication instance before views can be created or fonts
// measured, and the selftest builds a real toolbar to check its geometry. This
// is created up front and simply never run in the headless modes.
//
// The policy is set before any view is built, not only before `run()`, so the
// selftest measures the same bezel metrics the shipping app draws with: AppKit
// picks a button's bezel insets from the binary's recorded SDK version, and a
// mismatch between the two would make the selftest's widths describe a window
// the app never builds. (An earlier comment here blamed the system font for a
// 16% widening under `.prohibited`; measuring the fonts disproved that — the
// recorded SDK was the real cause.)
let application = NSApplication.shared
application.setActivationPolicy(.regular)

if arguments.count >= 3, arguments[1] == "--make-sample" {
    SampleChartWriter.write(to: arguments[2], multi: arguments.contains("--multi"))
    exit(0)
}

if arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
