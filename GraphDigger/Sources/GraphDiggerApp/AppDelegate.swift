import AppKit
import GDCore
import UniformTypeIdentifiers

/// The project file's type, as declared in the app bundle's `Info.plist`.
///
/// `UTType(exportedAs:)` rather than a literal every time a panel is built: the
/// identifier is written in three places — here, the plist and the build script —
/// and this is the one the compiler can check against `ProjectFile`.
extension UTType {
    static let graphDiggerProject = UTType(exportedAs: ProjectFile.typeIdentifier,
                                           conformingTo: .data)
}

/// Window, menu bar, toolbar, sheets and dialogs.
///
/// The toolbar carries the everyday workflow; the menu bar keeps the same
/// actions plus the ones used rarely. Everything that needs a window-level
/// response (sheets, panels) routes through here so the canvas stays purely
/// about drawing and hit-testing.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    /// Not private, like `buildMenu()` above it: the selftest drives the file
    /// commands through this canvas, because the guard that keeps one document
    /// from silently replacing another is only reachable through a modal alert.
    var canvas: CanvasView!
    private var toolbar: ToolbarView!
    private var bitmap: InfoBarView!
    private var sidebar: SidebarView!

    /// The two Edit-menu entries, so `refreshUI` can name the action each would
    /// take back — 「撤销 擦除」 rather than a bare 「撤销」, which leaves the user
    /// guessing how far back it goes.
    private var undoMenuItem: NSMenuItem!
    private var redoMenuItem: NSMenuItem!

    /// The two grid-direction entries, so `refreshUI` can put the tick on the one
    /// in force. A submenu is the only place on screen that says which way the
    /// grid currently runs — the strip's readout is 58pt wide and holds a number,
    /// not a word.
    private var gridAxisItems: [GridAxis: NSMenuItem] = [:]

    /// The tick beside 「显示原图」, kept so `refreshUI` can move it.
    private var showsImageMenuItem: NSMenuItem!

    /// The two decimal-separator entries, for the same reason as the grid ones:
    /// a submenu is the only place that says which way exports are currently
    /// written, and the answer is needed *before* a file is produced — the status
    /// line would say it only after.
    private var decimalSeparatorItems: [DecimalSeparator: NSMenuItem] = [:]

    /// The data-space plot (FR-7.1), built the first time it is asked for.
    ///
    /// Held rather than rebuilt so the window keeps its position and size, and
    /// because a second window showing the same document has to be *updated*
    /// with it rather than re-created from it.
    private var dataPlotWindow: NSWindow?
    private var dataPlotView: DataPlotView?

    /// The project file this document was opened from, or last saved to.
    ///
    /// Nil after opening a bare image and before the first save: `⌘S` then has
    /// nowhere to go, and the save panel is what turns the image into a project.
    private var projectURL: URL?

    /// Whether the user has already answered the save prompt with 「不保存」.
    ///
    /// Closing the window and quitting are two separate questions to AppKit —
    /// with no windows left the app is asked to terminate, which runs the same
    /// check a second time. Without this, choosing 「不保存」 would be followed
    /// immediately by the same dialog.
    private var discardConfirmed = false

    /// An open-document event can arrive before `applicationDidFinishLaunching`
    /// has built the window, so the URL is parked here and applied afterwards.
    private var pendingDocumentURL: URL?

    // MARK: - Export preferences

    /// Where the export preference is remembered between launches.
    ///
    /// `UserDefaults` and not the project file, because it is not a property of
    /// the chart: which spelling of `1.5` the file needs depends on the
    /// spreadsheet at the far end, so the same project may have to go out both
    /// ways in one afternoon. Which also means it must survive a launch — a
    /// European user who has to re-pick it every morning will simply forget, and
    /// then wonder why a colleague's Excel shows one column of text.
    ///
    /// **A seam, not a convenience.** The selftest is a real run of the real
    /// binary, so writing through `.standard` there would quietly change the
    /// setting of whoever ran it. The selftest points this at a throwaway suite.
    var exportPreferences: UserDefaults = .standard

    private static let decimalSeparatorKey = "decimalSeparator"

    /// The separator exports are currently written with. Read on every export
    /// rather than cached, so the menu, the save panel and the clipboard can
    /// never disagree about it.
    var exportDecimalSeparator: DecimalSeparator {
        get {
            exportPreferences.string(forKey: Self.decimalSeparatorKey)
                .flatMap(DecimalSeparator.init(rawValue:)) ?? .dot
        }
        set { exportPreferences.set(newValue.rawValue, forKey: Self.decimalSeparatorKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        if let url = pendingDocumentURL {
            pendingDocumentURL = nil
            openDocument(at: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The one place a quit is stopped. The window's own close goes through
    /// `windowShouldClose`, which asks the same question before the window is
    /// allowed to go; this covers `⌘Q`, where there is no window event at all.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmClosingTheDocument() ? .terminateNow : .terminateCancel
    }

    /// Lets a project file or a chart image be opened by dropping it on the icon
    /// or double-clicking it with GraphDigger as the handler — which is the whole
    /// point of the project format: the recipient needs the app and nothing else.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if window == nil {
            pendingDocumentURL = url
        } else {
            openDocument(at: url)
        }
    }

    /// Opens whatever was handed over, deciding by the file's own extension.
    ///
    /// By the file, not by which command was invoked: the open panel accepts both
    /// kinds and a double-clicked file arrives with no command at all, so a
    /// decision made per call site would be wrong for one of them.
    /// **Every** way of replacing the document funnels through here — `⌘O`, a
    /// double-click in the Finder, a drop on the icon, and the file handed over
    /// at launch — and every one of them has to ask before discarding what is on
    /// screen.
    ///
    /// They did not. The guard existed and was wired to `⌘Q` and to the close
    /// button, but not to this path, so picking a second image from the open
    /// panel threw away the calibration, the curves and every point of the first
    /// one without a word — and then cleared the modified dot as well, so the
    /// window looked *more* saved afterwards than before. The one moment a user
    /// is least likely to be watching is the one where he has just asked to look
    /// at something else.
    /// Not private: the selftest calls this directly, which is the only way to
    /// see that all four ways in ask the same question first.
    func openDocument(at url: URL) {
        guard confirmClosingTheDocument() else { return }
        // The answer is spent here, whatever happens next. If the file turns out
        // to be unreadable the old document is still on screen and still
        // unsaved, so a 「不保存」 meant for this attempt must not be carried over
        // to the next close.
        discardConfirmed = false
        if url.pathExtension.lowercased() == ProjectFile.fileExtension {
            openProject(at: url)
        } else {
            loadImage(at: url)
        }
    }

    // MARK: - Window

    /// Not private: the selftest builds a real window and then calls the real
    /// file commands on it. See `canvas` above.
    func buildWindow() {
        let toolbarHeight = MainLayout.toolbarHeight

        // Measured before the window exists so the minimum width is derived
        // from the toolbar rather than hard-coded: the button row is a fixed
        // width, and a narrower window would clip its right-hand buttons. The
        // frame is deliberately far wider than the screen — it only has to be
        // wide enough that the row lays itself out in full, and nothing is
        // displayed from it.
        toolbar = ToolbarView(frame: NSRect(x: 0, y: 0, width: 4_000,
                                            height: toolbarHeight))
        toolbar.delegate = self

        // The window must be wide enough for the whole toolbar row *and* the
        // data panel, or the panel would squeeze the canvas to nothing. Both
        // minima matter — the canvas column has to stay usable and the button
        // row has to fit inside it — so the window is their sum, not the larger
        // of the two. See `MainLayout.windowMinimumWidth`.
        //
        // The row is laid out first, at a width that certainly fits the screen:
        // it is what the minimum is measured from, and the arithmetic estimate
        // cannot be trusted to agree with it. See `ToolbarView.requiredWidth`.
        toolbar.layoutSubtreeIfNeeded()
        let minWidth = MainLayout.windowMinimumWidth(toolbarWidth: toolbar.requiredWidth)
        let contentRect = NSRect(x: 0, y: 0, width: minWidth + 60, height: 840)

        window = NSWindow(contentRect: contentRect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "GraphDigger"
        window.center()
        window.minSize = NSSize(width: minWidth, height: 620)
        // So closing the window asks about unsaved work *before* the window goes,
        // rather than after — by which point cancelling would leave the app
        // running with nothing to show.
        window.delegate = self

        // Auto Layout rather than autoresizing masks: the masks had the toolbar
        // pinned by the *wrong* margin, so going fullscreen slid it into the
        // middle and the canvas — added later, drawn on top — hid it entirely.
        // Constraints express the intended geometry directly.
        let container = NSView(frame: contentRect)
        canvas = CanvasView(frame: .zero)
        canvas.delegate = self

        bitmap = InfoBarView(frame: .zero)
        bitmap.delegate = self

        let sidebar = SidebarView(frame: .zero)
        sidebar.delegate = self
        self.sidebar = sidebar

        MainLayout.install(container: container, toolbar: toolbar, canvas: canvas,
                           sidebar: sidebar, infoBar: bitmap,
                           toolbarHeight: toolbarHeight)

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshUI()
    }

    // MARK: - Menu

    /// Not private: the selftest builds the real menu to check its shortcuts.
    ///
    /// A collision between two items' key equivalents is completely silent —
    /// AppKit fires whichever comes first and never mentions the other — and the
    /// only way to see it is to look at the finished menu. One pair was already
    /// here (⌘R on both 清除标定并重来 and 重新选点) before anything checked.
    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About GraphDigger",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit GraphDigger",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // ---- Edit -------------------------------------------------------
        // There was no Edit menu until undo arrived, and an undo with no ⌘Z is an
        // undo nobody finds. It sits where every other Mac app puts it, between
        // the application menu and File.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        undoMenuItem = NSMenuItem(title: "撤销", action: #selector(undoAction(_:)),
                                  keyEquivalent: "z")
        editMenu.addItem(undoMenuItem)
        redoMenuItem = NSMenuItem(title: "重做", action: #selector(redoAction(_:)),
                                  keyEquivalent: "z")
        redoMenuItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoMenuItem)
        editItem.submenu = editMenu

        // ---- File -------------------------------------------------------
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        // One 「打开…」 for both kinds of file. Two entries would make the user
        // work out which sort of document they are holding before they can ask
        // for it, when the file itself already says — and ⌘O keeps meaning what
        // it always meant for the images this app used to open.
        fileMenu.addItem(withTitle: "打开…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "保存项目", action: #selector(saveProject(_:)), keyEquivalent: "s")
        let saveAsItem = NSMenuItem(title: "项目另存为…", action: #selector(saveProjectAs(_:)),
                                    keyEquivalent: "s")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAsItem)
        fileMenu.addItem(.separator())

        let exportItem = NSMenuItem(title: "Export Data", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu(title: "Export Data")
        for format in ExportFormat.allCases {
            let item = NSMenuItem(title: format.displayName,
                                  action: #selector(exportData(_:)), keyEquivalent: "")
            item.representedObject = format.rawValue
            exportMenu.addItem(item)
        }
        exportItem.submenu = exportMenu
        fileMenu.addItem(exportItem)

        // The same list, narrowed to the curve in hand. Worth a second submenu
        // rather than a modifier on the first: five curves out of a paper and one
        // of them wanted is the ordinary case, and the alternative was exporting
        // all five and deleting four columns by hand.
        let exportActiveItem = NSMenuItem(title: "Export Current Curve (只导出当前曲线)",
                                          action: nil, keyEquivalent: "")
        let exportActiveMenu = NSMenu(title: "Export Current Curve")
        for format in ExportFormat.allCases {
            let item = NSMenuItem(title: format.displayName,
                                  action: #selector(exportCurrentCurve(_:)), keyEquivalent: "")
            item.representedObject = format.rawValue
            exportActiveMenu.addItem(item)
        }
        exportActiveItem.submenu = exportActiveMenu
        fileMenu.addItem(exportActiveItem)

        // How those two write their numbers — placed against them because that is
        // what it changes, and a submenu with a tick rather than a pair of
        // commands because it is a setting the user has to be able to *read back*
        // before choosing a format, not after.
        let decimalItem = NSMenuItem(title: "导出小数分隔符 (Decimal Separator)",
                                     action: nil, keyEquivalent: "")
        let decimalMenu = NSMenu(title: "Decimal Separator")
        for separator in DecimalSeparator.allCases {
            let item = NSMenuItem(title: separator.displayName,
                                  action: #selector(chooseDecimalSeparator(_:)),
                                  keyEquivalent: "")
            item.representedObject = separator.rawValue
            item.toolTip = separator.hint
            decimalMenu.addItem(item)
            decimalSeparatorItems[separator] = item
        }
        decimalItem.submenu = decimalMenu
        fileMenu.addItem(decimalItem)

        fileMenu.addItem(withTitle: "Copy Data to Clipboard (复制全部曲线)",
                         action: #selector(copyData(_:)), keyEquivalent: "c")
        let copyActive = NSMenuItem(title: "Copy Current Curve (复制当前曲线)",
                                    action: #selector(copyCurrentCurve(_:)), keyEquivalent: "c")
        copyActive.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(copyActive)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        // ---- Operations --------------------------------------------------
        let opsItem = NSMenuItem()
        main.addItem(opsItem)
        let opsMenu = NSMenu(title: "Operations")

        func addTool(_ title: String, _ raw: String, _ key: String,
                     _ modifiers: NSEvent.ModifierFlags = [.command]) {
            let item = NSMenuItem(title: title, action: #selector(selectTool(_:)), keyEquivalent: key)
            item.representedObject = raw
            item.keyEquivalentModifierMask = modifiers
            opsMenu.addItem(item)
        }

        addTool("Browse (浏览)", "browse", "0")
        opsMenu.addItem(.separator())
        // The plain letter goes to the everyday action; the rarer or more
        // destructive one keeps its letter a modifier over. That is the rule
        // behind both of these, and it is the rule the File menu follows too.
        //
        // ⌥⌘S, not ⌘S. 标定 held ⌘S from the beginning, when the app had no
        // documents to save; now that it does, ⌘S has to mean 保存 — it is what
        // every Mac user's hand does without asking, and the mistake it would
        // otherwise cause is a bad one. If the coordinate system is already set,
        // a stray ⌘S meant for 保存 would offer to throw it away; if it is not,
        // the next four clicks on the chart would silently be eaten as
        // calibration anchors.
        addTool("Set the Scale (标定坐标系)", "setScale", "s", [.command, .option])
        addTool("Edit Calibration Values (修改标定数值)…", "editCalibration", "")
        // ⌥⌘R for the same reason, and it repairs a collision that was already
        // here: 清除标定并重来 and 重新选点 were both written with ⌘R. AppKit
        // silently fires whichever comes first and never mentions the loser, so
        // 重新选点 has been unreachable from the keyboard all along — and it is
        // the one of the two that is a *tool*, sitting in the toolbar beside
        // 橡皮擦. It takes the plain key; the destructive one moves over.
        addTool("Recalibrate (清除标定并重来)", "recalibrate", "r", [.command, .option])
        opsMenu.addItem(.separator())
        addTool("Pick Curve Color (取曲线颜色)", "pickLineColor", "l")
        addTool("Pick Background Color (取背景颜色)", "pickBackgroundColor", "k")
        addTool("Color Tolerance…", "tolerance", "")
        opsMenu.addItem(.separator())
        addTool("Digitize Area (区域取点)", "gridDigitize", "d")
        addTool("Auto Trace Line (自动跟踪)", "traceDigitize", "t")
        // ⌘M for Match, next to the two tools it is an alternative to. It would be
        // Minimize on a Mac with a Window menu; this app builds none, so the key
        // was free and the mnemonic beats the letter being unclaimed.
        addTool("Match Symbols (符号匹配)", "symbolMatch", "m")
        addTool("Point Capture (手工取点)", "capture", "p")
        addTool("Eraser (橡皮擦)", "eraser", "e")
        // ⇧⌘E, one modifier over the eraser's ⌘E: this is the same job at a finer
        // grain — 橡皮擦 acts on everything inside a ring, 点编辑 on the one marker
        // under the pointer — so the letter belongs to the pair and the modifier
        // says which of the two. It is also the only repair tool here that can
        // *add* a point, which the eraser and 重新选点 both cannot.
        addTool("Edit Point (点编辑)", "editPoint", "e", [.command, .shift])
        addTool("Re-digitize (重新选点)", "redigitize", "r")
        opsMenu.addItem(.separator())
        opsMenu.addItem(withTitle: "Add Curve (新增曲线)",
                        action: #selector(addLine(_:)), keyEquivalent: "n")
        opsMenu.addItem(withTitle: "Delete Current Curve (删除当前曲线)",
                        action: #selector(deleteLine(_:)), keyEquivalent: "")
        opsMenu.addItem(withTitle: "Clear Points on Current Curve",
                        action: #selector(clearPoints(_:)), keyEquivalent: "")
        opsMenu.addItem(.separator())
        let orderItem = NSMenuItem(title: "Point Order (取点顺序)", action: nil, keyEquivalent: "")
        let orderMenu = NSMenu(title: "Point Order")
        for order in PointOrder.allCases {
            let item = NSMenuItem(title: order.displayName,
                                  action: #selector(setPointOrder(_:)), keyEquivalent: "")
            item.representedObject = order.rawValue
            orderMenu.addItem(item)
        }
        orderItem.submenu = orderMenu
        opsMenu.addItem(orderItem)
        opsMenu.addItem(.separator())
        // 点重排 sits with the tools rather than among the order menu's entries:
        // the four order modes are choices about the points, while this is a
        // gesture that produces a fifth order nothing else can name.
        addTool("Reorder Points by Sweep (点重排)", "reorder", "b")
        opsMenu.addItem(withTitle: "Clear Reorder (清除重排)",
                        action: #selector(clearReorder(_:)), keyEquivalent: "")
        opsMenu.addItem(.separator())
        // The sampling spacings are set by the knob in the info bar, which is
        // where the eye already goes when the tool is selected. The menu entries
        // stay as a second, typed route — the menu bar is expected to list every
        // command — but they open a field rather than being the only way in,
        // which is what the user complained about: 网格间距 was reachable only
        // from here and undiscoverable, and the trace density not at all.
        opsMenu.addItem(withTitle: "网格间距 (Grid Spacing)…",
                        action: #selector(setGridSpacing(_:)), keyEquivalent: "")
        opsMenu.addItem(withTitle: "取点密度 (Trace Density)…",
                        action: #selector(setTraceSpacing(_:)), keyEquivalent: "")

        // The grid's two shape options sit beside its spacing, because all three
        // are what the next 框选 will do and none of them applies to any other
        // tool. The direction is a submenu with a tick rather than a pair of
        // commands because it is a mode the user needs to *read back* — 「现在是
        // 哪种网格」 has no other answer on screen, and the strip's readout has 58
        // points of width, which is not enough for the word.
        let gridItem = NSMenuItem(title: "网格方向 (Grid Axis)", action: nil, keyEquivalent: "")
        let gridMenu = NSMenu(title: "Grid Axis")
        for axis in GridAxis.allCases {
            let item = NSMenuItem(title: axis.displayName,
                                  action: #selector(setGridAxis(_:)), keyEquivalent: "")
            item.representedObject = axis.rawValue
            item.toolTip = axis.hint
            gridMenu.addItem(item)
            gridAxisItems[axis] = item
        }
        gridItem.submenu = gridMenu
        opsMenu.addItem(gridItem)
        opsMenu.addItem(withTitle: "网格对齐到坐标轴起点 (Align Grid to Axis Origin)",
                        action: #selector(alignGridToAxisOrigin(_:)), keyEquivalent: "")
        opsMenu.addItem(withTitle: "网格偏移 (Grid Phase)…",
                        action: #selector(setGridPhase(_:)), keyEquivalent: "")
        opsItem.submenu = opsMenu

        // ---- View --------------------------------------------------------
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Fit to Window", action: #selector(zoomToFit(_:)), keyEquivalent: "9")
        viewMenu.addItem(.separator())
        // The two views that exist to *check* the work rather than to do it. Both
        // are looking aids, so both live here and neither is in the undo history.
        let showImage = NSMenuItem(title: "Show Image (显示原图)",
                                   action: #selector(toggleShowsImage(_:)), keyEquivalent: "i")
        showImage.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(showImage)
        showsImageMenuItem = showImage

        let dataView = NSMenuItem(title: "Data View (数据视图)",
                                  action: #selector(showDataPlot(_:)), keyEquivalent: "d")
        dataView.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(dataView)
        viewItem.submenu = viewMenu

        NSApp.mainMenu = main
    }

    // MARK: - Files

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.graphDiggerProject, .image]
        panel.message = "选择 GraphDigger 项目(.\(ProjectFile.fileExtension)),或一张图表图片"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openDocument(at: url)
    }

    private func loadImage(at url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            presentError("无法读取 \(url.lastPathComponent)。")
            return
        }
        // The bytes are read as well as the image, and kept: a project save
        // writes them back rather than re-encoding, because every digitised point
        // is a coordinate into this exact image. Reading the file twice — once as
        // data, once through ImageIO — is cheaper than the alternative of
        // re-encoding the picture and hoping it round-trips.
        //
        // The result is checked rather than assumed: `NSImage` decodes lazily, so
        // a truncated or half-copied file yields an object that only fails when
        // something asks for its pixels.
        guard canvas.load(image: image, data: try? Data(contentsOf: url),
                          name: url.lastPathComponent) else {
            presentError("\(url.lastPathComponent) 的像素读不出来 —— 文件可能已损坏或被截断。")
            return
        }
        canvas.zoomToFit()
        // An image on its own is not a project yet: ⌘S has to ask where to put
        // one, and the baseline is "nothing has been done to this picture".
        projectURL = nil
        canvas.markSaved()
        refreshUI("已载入 \(url.lastPathComponent) —— 标定坐标系后即可取点")
    }

    /// Opens a saved project: image, calibration and every curve, in one go.
    private func openProject(at url: URL) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            presentError("读不到 \(url.lastPathComponent):\(error.localizedDescription)")
            return
        }

        let document: ProjectDocument
        do {
            document = try ProjectDocument(serialized: data)
        } catch {
            // `ProjectFileError` says something the user can act on — truncated,
            // a newer format, damaged — so it is surfaced as written rather than
            // wrapped in a generic failure.
            presentError((error as? ProjectFileError)?.localizedDescription
                ?? "项目文件无法解析:\(error.localizedDescription)")
            return
        }

        guard canvas.load(project: document) else {
            presentError("项目文件里的图片无法解码 —— 文件可能已损坏。"
                + "标定与曲线数据仍是完好的,但需要原始图片才能显示。")
            return
        }

        projectURL = url
        canvas.markSaved()
        canvas.zoomToFit()
        // A reopened project is not in the middle of anything: the tool goes back
        // to 浏览 so the first click pans rather than drawing.
        canvas.tool = .browse
        refreshUI(projectSummary(prefix: "已打开 \(url.lastPathComponent)"))
    }

    /// What the status line says a project contains, spelled the same way whether
    /// it has just been opened or just been written.
    private func projectSummary(prefix: String) -> String {
        let state = canvas.state
        var parts = ["图片"]
        if state.calibration != nil { parts.append("标定") }
        parts.append("\(state.lines.count) 条曲线 \(state.totalPointCount) 点")
        return "\(prefix)(\(parts.joined(separator: " + ")))"
    }

    @objc private func saveProject(_ sender: Any?) {
        // No file yet — an image that has never been saved as a project, or a
        // project opened from somewhere that has since moved — so ask where.
        guard let url = projectURL else {
            saveProjectAs(sender)
            return
        }
        writeProject(to: url)
    }

    @objc private func saveProjectAs(_ sender: Any?) {
        saveProjectChoosingLocation()
    }

    /// The save panel half of both save commands. Returns whether a file was
    /// actually written, which is what the quit prompt needs: cancelling the
    /// panel is a decision not to save, and therefore not to close.
    @discardableResult
    private func saveProjectChoosingLocation() -> Bool {
        guard canvas.buffer != nil else {
            presentError("还没有打开图片,没有可保存的项目。")
            return false
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.graphDiggerProject]
        panel.nameFieldStringValue = suggestedProjectName()
        panel.message = "图片、标定坐标系与曲线数据会一起写进这一个文件"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return writeProject(to: url)
    }

    /// A project named after the chart, so the two are recognisable side by side
    /// in the Finder. Falls back only when the image arrived with no name at all.
    private func suggestedProjectName() -> String {
        let stem = (canvas.imageName as NSString?)?.deletingPathExtension ?? ""
        let base = stem.trimmingCharacters(in: .whitespaces).isEmpty ? "图表" : stem
        return "\(base).\(ProjectFile.fileExtension)"
    }

    /// Writes the whole document, and reports whether it landed.
    @discardableResult
    private func writeProject(to url: URL) -> Bool {
        guard let document = canvas.projectDocument(appVersion: appVersion) else {
            presentError("还没有打开图片,没有可保存的项目。")
            return false
        }
        do {
            try document.serialized().write(to: url, options: .atomic)
        } catch let error as ProjectFileError {
            presentError(error.localizedDescription)
            return false
        } catch {
            presentError("写入失败:\(error.localizedDescription)")
            return false
        }

        projectURL = url
        // The baseline moves to what was just written, which is also what clears
        // the edited dot: the file and the screen are the same document again.
        canvas.markSaved()
        discardConfirmed = false
        refreshUI(projectSummary(prefix: "已保存 \(url.lastPathComponent)"))
        return true
    }

    /// The app's own version, recorded in the file so a misbehaving project can
    /// be traced to the build that wrote it.
    private var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    // MARK: - Data view

    @objc private func toggleShowsImage(_ sender: Any?) {
        canvas.showsImage.toggle()
        refreshUI(canvas.showsImage ? "显示原图" : "已隐藏原图 —— 只留取到的点")
    }

    /// Opens the data-space plot, or brings it forward if it is already up.
    ///
    /// Its own window because there is nowhere else to put it: the toolbar has
    /// 13pt of width to spare and the side panel is 272pt wide against a 1440pt
    /// screen, and a plot that has to be *read* needs more than either.
    @objc private func showDataPlot(_ sender: Any?) {
        if dataPlotWindow == nil {
            let view = DataPlotView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
            let window = NSWindow(contentRect: view.frame,
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "数据视图"
            window.contentView = view
            window.minSize = NSSize(width: 320, height: 240)
            window.isReleasedWhenClosed = false
            window.center()
            // Offset from the main window so the two can be seen together, which
            // is the entire point of it being a second window.
            if let main = self.window {
                window.setFrameTopLeftPoint(NSPoint(x: main.frame.minX - 40,
                                                    y: main.frame.maxY + 30))
            }
            dataPlotWindow = window
            dataPlotView = view
        }
        dataPlotView?.state = canvas.state
        dataPlotWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Closing

    /// The data view is a view *of* the document, so it goes when the document
    /// does. Left behind it would keep the app alive with nothing to show: the
    /// last window is what tells AppKit to quit.
    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        dataPlotWindow?.close()
    }

    /// Asks before anything discards work that lives only in memory.
    ///
    /// Everything here does: the calibration, the curves, and the image itself,
    /// which sits *inside* the project file rather than beside it — so an image
    /// that was opened and calibrated but never saved has no second copy on disk.
    private func confirmClosingTheDocument() -> Bool {
        if discardConfirmed { return true }
        guard hasUnsavedChanges else { return true }

        switch askAboutUnsavedChanges() {
        case .alertFirstButtonReturn:
            // A cancelled save panel is not a yes: the file was never written, so
            // closing now would discard the work the user just asked to keep.
            return projectURL.map { writeProject(to: $0) } ?? saveProjectChoosingLocation()
        case .alertSecondButtonReturn:
            discardConfirmed = true
            return true
        default:
            return false
        }
    }

    /// Puts the question to the user. Substituted by the selftest.
    ///
    /// A seam on the instance rather than a parameter on
    /// `confirmClosingTheDocument` because the callers that matter are all
    /// *inside* the app — the open panel, the launch hand-off, the window
    /// delegate — and none of them is in a position to pass one along. It is also
    /// the only way to reach the cancel branch: an `NSAlert.runModal()` cannot be
    /// driven head-lessly, and a guard that is never seen to refuse is a guard
    /// nobody has actually checked.
    var unsavedChangesPrompt: (() -> NSApplication.ModalResponse)?

    private func askAboutUnsavedChanges() -> NSApplication.ModalResponse {
        if let prompt = unsavedChangesPrompt { return prompt() }
        let alert = NSAlert()
        alert.messageText = "要保存对项目的修改吗?"
        alert.informativeText = "项目里包含图片、标定坐标系和 \(canvas.state.totalPointCount) 个数据点,"
            + "不保存就关掉会全部丢失。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        return alert.runModal()
    }

    /// Whether the document has edits a save would capture. The canvas owns the
    /// comparison — it is what knows when the state changed, and holding a second
    /// copy of the baseline out here would be the flag problem over again.
    private var hasUnsavedChanges: Bool { canvas.hasUnsavedChanges }

    /// Keeps the window's own document affordances in step: what the file is
    /// called, where it lives, and whether the copy on disk is behind the screen.
    ///
    /// The dot in the close button is the platform's own "unsaved" signal — the
    /// one a Mac user already looks for — so it is driven from here rather than
    /// invented as a badge somewhere in the toolbar, which has no width to spare
    /// and would be a second vocabulary for the same fact.
    private func updateDocumentChrome() {
        guard canvas.buffer != nil else {
            window.title = "GraphDigger"
            window.representedURL = nil
            window.isDocumentEdited = false
            return
        }
        // The project's name once it has one, the image's until then.
        let name = projectURL?.lastPathComponent
            ?? canvas.imageName
            ?? "未命名项目"
        window.title = "GraphDigger — \(name)"
        window.representedURL = projectURL
        window.isDocumentEdited = hasUnsavedChanges
    }

    @objc private func exportData(_ sender: Any?) {
        exportCommand(sender, onlyActive: false)
    }

    @objc private func exportCurrentCurve(_ sender: Any?) {
        exportCommand(sender, onlyActive: true)
    }

    /// Both export menus land here; only the set of curves differs.
    private func exportCommand(_ sender: Any?, onlyActive: Bool) {
        // From the toolbar the format is chosen by a small menu; from the menu
        // bar the item already carries one.
        if let item = sender as? NSMenuItem, let raw = item.representedObject as? String,
           let format = ExportFormat(rawValue: raw) {
            performExport(format: format, relativeTo: nil, onlyActive: onlyActive)
        } else {
            presentFormatChooser(onlyActive: onlyActive)
        }
    }

    /// The curves a command applies to: the one in hand, or all of them.
    ///
    /// The active curve, not "the first one": the point of the command is to get
    /// *this* curve out, and the user has already said which one that is by
    /// selecting it.
    private func curvesForExport(onlyActive: Bool) -> [CurveLine] {
        guard onlyActive, let active = canvas.state.activeLine else { return canvas.state.lines }
        return [active]
    }

    private func presentFormatChooser(onlyActive: Bool) {
        let alert = NSAlert()
        alert.messageText = "导出为哪种格式?"
        alert.informativeText = "CSV / TSV 最通用;DXF 给 CAD;EPS 是矢量图。"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        popup.addItems(withTitles: ExportFormat.allCases.map(\.displayName))
        alert.accessoryView = popup
        alert.addButton(withTitle: "导出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let format = ExportFormat.allCases[max(0, popup.indexOfSelectedItem)]
        performExport(format: format, relativeTo: nil, onlyActive: onlyActive)
    }

    /// The bytes an export would write, preferences and all.
    ///
    /// Split out of `performExport` because the save panel that follows cannot be
    /// answered without a person, and the only way to see what the decimal
    /// separator *does* is to look at the bytes it produced. Not private, so the
    /// selftest can look.
    func exportPayload(format: ExportFormat, onlyActive: Bool = false) throws -> Data {
        try Exporter.data(for: curvesForExport(onlyActive: onlyActive),
                          calibration: canvas.state.calibration,
                          format: format,
                          decimalSeparator: exportDecimalSeparator)
    }

    /// The same, for the clipboard — split out for the same reason, and so the
    /// "which curves, which separator" decision has one home rather than two.
    /// The checks read it instead of driving the real pasteboard, which is global
    /// state a head-less run has no business overwriting.
    func clipboardText(onlyActive: Bool = false) throws -> String {
        try Exporter.text(for: curvesForExport(onlyActive: onlyActive),
                          calibration: canvas.state.calibration,
                          format: .tsv,
                          decimalSeparator: exportDecimalSeparator)
    }

    private func performExport(format: ExportFormat, relativeTo sender: NSView?,
                               onlyActive: Bool = false) {
        // Bytes rather than text: the workbook is a ZIP, and routing every format
        // through one call is what keeps the save panel from having to know which
        // formats happen to be strings.
        let lines = curvesForExport(onlyActive: onlyActive)
        let payload: Data
        do {
            payload = try exportPayload(format: format, onlyActive: onlyActive)
        } catch {
            presentExportError(error)
            return
        }

        let panel = NSSavePanel()
        // Named after the curve when there is only one, so a folder of single
        // exports is navigable rather than a row of `digitized.csv`.
        panel.nameFieldStringValue = (lines.count == 1
            ? Self.fileNameStem(lines[0].name)
            : "digitized") + ".\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try payload.write(to: url, options: .atomic)
            refreshUI("已导出 \(lines.count) 条曲线到 \(url.lastPathComponent)")
        } catch {
            presentError("写入失败:\(error.localizedDescription)")
        }
    }

    @objc private func copyData(_ sender: Any?) {
        copyToClipboard(onlyActive: false)
    }

    @objc private func copyCurrentCurve(_ sender: Any?) {
        copyToClipboard(onlyActive: true)
    }

    /// TSV, because that is what a spreadsheet pastes. Several curves arrive as a
    /// wide table — one x/y pair per curve — since that is what lines up with
    /// columns; the labelled-block layout would paste each name into a cell of
    /// its own and shift everything below it.
    ///
    /// The decimal separator matters here as much as in a saved file: the paste
    /// lands in the same Excel the file would have been read by. A tab is not a
    /// decimal point, so TSV needs no separator swap — only the numbers' spelling.
    private func copyToClipboard(onlyActive: Bool) {
        let lines = curvesForExport(onlyActive: onlyActive)
        let text: String
        do {
            text = try clipboardText(onlyActive: onlyActive)
        } catch {
            presentExportError(error)
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        let count = lines.reduce(0) { $0 + $1.points.count }
        refreshUI("已复制 \(lines.count) 条曲线的 \(count) 个数据点到剪贴板")
    }

    /// A curve name fit to be a file name: a `/` in a name would silently become
    /// a directory separator, and an empty name would leave a file called ".csv".
    private static func fileNameStem(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "digitized" : cleaned
    }

    private func presentExportError(_ error: Error) {
        switch error {
        case ExportError.calibrationMissing:
            presentError("还没有标定坐标系。请先点「标定坐标系」建立坐标系,数据才能换算成实际数值。")
        case ExportError.noPoints:
            presentError("当前没有已提取的数据点。先用「区域取点」或「自动跟踪」取点。")
        default:
            presentError("导出失败:\(error.localizedDescription)")
        }
    }

    // MARK: - 导出小数分隔符

    /// Sets how exports spell their numbers — FR-11.
    ///
    /// Not private: the selftest drives this rather than poking the preference,
    /// because the setting's only observable effect is on the bytes an export
    /// produces and the panel that would show them needs a person to answer it.
    ///
    /// It is worth saying out loud in the status line even though nothing on
    /// screen changes, because it changes the *next file* — and the semicolon in
    /// the CSV is the part that surprises: a user who picks the comma and then
    /// opens the file in a US-locale tool sees one column, not two, and would
    /// otherwise have no way to tell that was the setting working as intended.
    func setDecimalSeparator(_ separator: DecimalSeparator) {
        exportDecimalSeparator = separator
        refreshUI(separator == .comma
                  ? "导出小数分隔符 = 逗号 —— 数值写成 1,5,CSV 的列改用分号分隔"
                  : "导出小数分隔符 = 句点 —— 数值写成 1.5,CSV 的列用逗号分隔")
    }

    @objc private func chooseDecimalSeparator(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let separator = DecimalSeparator(rawValue: raw) else { return }
        setDecimalSeparator(separator)
    }

    // MARK: - Undo

    /// Takes back the last action, whichever tool took it.
    ///
    /// Both the toolbar button and ⌘Z land here, so there is one path to check
    /// rather than two that can drift. The message names what went: a silent
    /// success on a canvas whose change is off-screen — the point the eraser took
    /// out ten seconds ago — is indistinguishable from a shortcut that did
    /// nothing.
    @objc private func undoAction(_ sender: Any?) {
        guard let label = canvas.undo() else {
            refreshUI("没有可撤销的操作了")
            return
        }
        refreshUI("已撤销:\(label)")
    }

    /// Puts back the action 撤销 took away, and names it in the status line.
    ///
    /// The counterpart to `undoAction`, reached by the 恢复 segment and by ⇧⌘Z.
    /// It exists because 撤销 over-reaches: one ⌘Z too many is the commonest way
    /// to end up with the wrong picture, and without a way back the only repair
    /// is to redo the work by hand.
    @objc private func redoAction(_ sender: Any?) {
        guard let label = canvas.redo() else {
            refreshUI("没有可重做的操作")
            return
        }
        refreshUI("已重做:\(label)")
    }

    // MARK: - Operations

    @objc private func selectTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        applyTool(raw)
    }

    private func applyTool(_ raw: String) {
        switch raw {
        case "recalibrate":         recalibrate()
        case "tolerance":           setTolerance(nil)
        case "setScale":            beginCalibration()
        case "editCalibration":     editCalibrationValues()
        case "pickLineColor":       canvas.tool = .pickLineColor
        case "pickBackgroundColor": canvas.tool = .pickBackgroundColor
        case "gridDigitize":        canvas.tool = .gridDigitize
        case "symbolMatch":         canvas.tool = .symbolMatch
        case "traceDigitize":       canvas.tool = .traceDigitize
        case "capture":             canvas.tool = .capture
        case "eraser":              canvas.tool = .eraser
        case "editPoint":           canvas.tool = .editPoint
        case "redigitize":          canvas.tool = .redigitize
        case "reorder":             canvas.tool = .reorder
        default:                    canvas.tool = .browse
        }
        refreshUI()
    }

    @objc private func addLine(_ sender: Any?) {
        canvas.addLine()
        refreshUI()
    }

    @objc private func deleteLine(_ sender: Any?) {
        canvas.removeActiveLine()
        refreshUI()
    }

    @objc private func clearPoints(_ sender: Any?) {
        canvas.clearActiveLinePoints()
        refreshUI()
    }

    @objc private func setPointOrder(_ sender: NSMenuItem) {
        guard let id = canvas.state.activeLineID else {
            presentError("请先在右侧面板选中一条曲线。")
            return
        }
        guard let raw = sender.representedObject as? String,
              let order = PointOrder(rawValue: raw) else { return }
        canvas.setOrder(order, for: id)
        refreshUI("取点顺序 = \(order.displayName)")
    }

    /// Throws away a sweep and puts the curve back in its extraction order.
    ///
    /// `⌘Z` also takes a sweep back, so this is not the *only* way out of one —
    /// but it is the one that does not require the sweep to be the last thing
    /// that happened, and it is why the sweep was stored beside the points rather
    /// than replacing them.
    @objc private func clearReorder(_ sender: Any?) {
        guard let id = canvas.state.activeLineID else {
            presentError("请先在右侧面板选中一条曲线。")
            return
        }
        guard canvas.state.activeLine?.sweptOrder != nil else {
            refreshUI("这条曲线还没有重排过")
            return
        }
        canvas.clearReorder(for: id)
        refreshUI("已清除重排 —— 曲线回到原来的取点顺序")
    }

    /// Enters calibration, refusing to throw away an existing one without a word.
    ///
    /// The canvas owns the policy (`beginCalibration(force:)`) so the refusal is
    /// testable; all this adds is the question and the retry. Once a coordinate
    /// system exists, re-calibrating means four more clicks and losing the old
    /// mapping, which is not something to do because a button was clicked by
    /// accident.
    private func beginCalibration() {
        if canvas.beginCalibration(force: false) {
            refreshUI()
            return
        }
        let alert = NSAlert()
        alert.messageText = "已经标定过了"
        alert.informativeText = "重新标定会覆盖现有的坐标系,需要重新点取 4 个标记。"
            + "已提取的数据点不会丢失(它们存的是像素位置)。确定要重来吗?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重新标定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = canvas.beginCalibration(force: true)
        refreshUI("已清除标定 —— 依次点取 X 轴起始、X 轴末端、Y 轴起始、Y 轴末端")
    }

    /// Edits the four calibration values without touching the clicked markers.
    private func editCalibrationValues() {
        guard let calibration = canvas.state.calibration,
              let anchors = canvas.state.calibrationAnchors else {
            presentError("还没有标定。请先点「标定坐标系」建立坐标系。")
            return
        }
        CalibrationSheet.present(in: window, anchors: anchors,
                                 previous: calibration, editing: true) { [weak self] map in
            guard let self, let map else { return }
            self.canvas.updateCalibrationValues(map)
            self.refreshUI("标定数值已更新 —— 四个标记位置不变")
        }
    }

    private func recalibrate() {
        guard canvas.state.calibration != nil else {
            canvas.tool = .setScale
            refreshUI()
            return
        }
        canvas.clearCalibration()
        canvas.tool = .setScale
        refreshUI("标定已清除。已提取的数据点保留不变,重新点取 3 个标记即可。")
    }

    /// The typed route to the two sampling spacings.
    ///
    /// Range and clamping come from `ToolParameter`, the same source the slider's
    /// travel does, so the field can never offer a value the knob cannot be
    /// dragged back to: two hand-written limits are how a control ends up showing
    /// a number it cannot reproduce.
    @objc private func setGridSpacing(_ sender: Any?) {
        guard let value = promptForNumber(for: .gridSpacing,
                                          title: "网格间距",
                                          message: "区域取点/重新选点时相邻扫描线的间隔(像素)。数值越小点越密。",
                                          current: Double(canvas.state.gridSpacing)) else { return }
        canvas.setGridSpacing(Int(value.rounded()))
        refreshUI("网格间距 = \(canvas.state.gridSpacing) px")
    }

    @objc private func setTraceSpacing(_ sender: Any?) {
        guard let value = promptForNumber(for: .traceSpacing,
                                          title: "取点密度",
                                          message: "自动跟踪时沿曲线每隔多少像素保留一个点。数值越小点越密,1 表示每个像素都取。",
                                          current: Double(canvas.state.traceSpacing)) else { return }
        canvas.setTraceSpacing(Int(value.rounded()))
        refreshUI("取点密度 = 每 \(canvas.state.traceSpacing) px 一点")
    }

    /// Turns the area grid a quarter turn — FR-5.4.
    ///
    /// Reported through the status line rather than a dialog because it changes
    /// what the *next* pass does, and the picture on screen does not move: without
    /// a word the click would be indistinguishable from one that failed, which is
    /// the same reason 适配窗口 answers even when it has nothing to do.
    @objc private func setGridAxis(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let axis = GridAxis(rawValue: raw) else { return }
        canvas.setGridAxis(axis)
        refreshUI("\(axis.displayName) —— \(axis.hint)")
    }

    /// Slides the grid so a scan line lands on the coordinate system's own start.
    ///
    /// This is the alignment that matters in practice. Samples are useful when
    /// they land on round data values, and the axis origin is the one pixel the
    /// app already knows the value of — so put a line there and every further
    /// line is a whole spacing away from it. Doing it by hand would mean reading
    /// a pixel off the chart and working out a residue modulo the spacing, which
    /// is exactly the arithmetic this can get wrong on the user's behalf.
    @objc private func alignGridToAxisOrigin(_ sender: Any?) {
        guard let anchors = canvas.state.calibrationAnchors else {
            presentError("还没有标定坐标系,网格不知道该对齐到哪一列。请先点「标定坐标系」建立坐标系。")
            return
        }
        let axis = canvas.state.areaDigitizingGrid.axis
        // An X grid's lines are columns, so the origin it aligns to is the column
        // the X axis starts at; a Y grid's are rows, so it is the Y axis' start
        // row. Taking the other one would line the grid up with a coordinate the
        // scans never touch.
        let pixel = axis == .x ? anchors.xStart.x : anchors.yStart.y
        canvas.alignGrid(toPixel: pixel, spacing: canvas.state.gridSpacing)
        refreshUI("网格已对齐到\(axis == .x ? "X 轴起点所在的列" : "Y 轴起点所在的行")"
            + "(第 \(Int(pixel.rounded())) 像素)")
    }

    /// The typed route to the grid's phase — FR-5.5.
    @objc private func setGridPhase(_ sender: Any?) {
        let dx = max(1, canvas.state.gridSpacing)
        guard let value = promptForNumber(title: "网格偏移",
                                          message: "扫描线落在哪些像素上:线位于「偏移 + 间距 × 整数」。"
                                              + "可填 0 到 \(dx - 1);再大就与下一个间距重合了。",
                                          current: Double(canvas.state.areaDigitizingGrid.phase),
                                          minimum: 0, maximum: Double(dx - 1)) else { return }
        canvas.alignGrid(toPixel: value, spacing: dx)
        refreshUI("网格偏移 = \(canvas.state.areaDigitizingGrid.phase) px")
    }

    @objc private func setTolerance(_ sender: Any?) {
        guard let value = promptForNumber(title: "颜色容差",
                                          message: "判定「属于曲线」的颜色距离阈值。曲线没取全就调大,取进太多杂点就调小。",
                                          current: canvas.activeColorTolerance,
                                          minimum: 1, maximum: 442) else { return }
        canvas.setColorTolerance(value)
        refreshUI("颜色容差 = \(Int(canvas.activeColorTolerance))")
    }

    /// A number typed in, bounded by the travel of the control that also sets it.
    private func promptForNumber(for parameter: ToolParameter, title: String,
                                 message: String, current: Double) -> Double? {
        let range = parameter.range
        return promptForNumber(title: title, message: message, current: current,
                               minimum: range.lowerBound, maximum: range.upperBound)
    }

    private func promptForNumber(title: String, message: String,
                                 current: Double,
                                 minimum: Double, maximum: Double) -> Double? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        field.stringValue = String(format: "%g", current)
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn,
              let value = Double(field.stringValue.trimmingCharacters(in: .whitespaces)),
              value >= minimum, value <= maximum else { return nil }
        return value
    }

    // MARK: - View

    @objc private func zoomIn(_ sender: Any?) { canvas.zoomIn() }
    @objc private func zoomOut(_ sender: Any?) { canvas.zoomOut() }
    @objc private func zoomToFit(_ sender: Any?) {
        let changed = canvas.zoomToFit()
        refreshUI(changed ? "已适配窗口" : "已是适配状态")
    }

    // MARK: - UI refresh

    /// Rebuilds the toolbar's step prompt, the status line and the data panel
    /// from current state. Every mutation path funnels through here, so the
    /// three views can never disagree about what the project currently contains.
    ///
    /// - Parameter reloadingPanel: false for the two commands that are driven from
    ///   *inside* the point table. An edit commits from
    ///   `controlTextDidEndEditing`, and rebuilding the table from within that
    ///   callback would tear down the cell whose field editor is still unwinding —
    ///   besides throwing away the scroll position and row selection of the list
    ///   the user is working in. The rest of the window still has to catch up, so
    ///   only the panel is skipped; the status line and the title bar's unsaved
    ///   dot are not. The deletion path keeps the full reload, because there the
    ///   row count changed and the table genuinely has a stale row.
    private func refreshUI(_ extra: String? = nil, reloadingPanel: Bool = true) {
        let hasImage = canvas.buffer != nil
        let calibrated = canvas.state.calibration != nil
        let lines = canvas.state.lines
        let active = canvas.state.activeLine
        let pointCount = canvas.state.totalPointCount

        toolbar.setActiveTool(canvas.tool)

        // The strip's right end shows the number the tool in hand works by — the
        // ring's size, or the spacing its sampling uses — and nothing for the
        // tools that have no such number. The control used to be the eraser's
        // alone and to sit there permanently; the two spacings it now also serves
        // were in the 操作 menu, one behind a modal dialog and one not adjustable
        // at all.
        let parameter = canvas.tool.parameter
        bitmap.setParameter(parameter, value: parameter.map { canvas.value(of: $0) } ?? 0)

        if reloadingPanel {
            sidebar.update(lines: lines,
                           calibration: canvas.state.calibration,
                           activeID: canvas.state.activeLineID)
        }

        // The step prompt walks the user through the pipeline in order, which is
        // what the menu bar could never convey. Readiness is judged per curve:
        // on a multi-curve chart the second curve still needs its own colour.
        let activeReady = active?.lineColor != nil
        let step: String
        if !hasImage {
            step = "第 1 步:打开一张图表图片 (⌘O)"
        } else if !calibrated {
            step = canvas.scalePrompt ?? "第 2 步:点「标定坐标系」建立坐标系"
        } else if !activeReady {
            step = active == nil
                ? "第 3 步:点「取曲线颜色」再点曲线 —— 会自动新建一条曲线"
                : "第 3 步:给「\(active!.name)」取色 —— 点「取曲线颜色」后点这条曲线"
        } else if pointCount == 0 {
            step = "第 4 步:点「区域取点」框选曲线,或「自动跟踪」点曲线起点"
        } else if active?.points.isEmpty == true {
            step = "「\(active!.name)」还没有点 —— 继续取点,或在右侧面板「新增曲线」换一条"
        } else {
            step = "数据已就绪 —— 可继续取点,或点「复制」/「导出…」"
        }

        var status: [String] = []
        if !calibrated { status.append("⚠️ 未标定") }
        if hasImage {
            if let active, active.lineColor == nil {
                status.append("⚠️「\(active.name)」未取色")
            }
            status.append(canvas.zoomDescription)
            if let background = canvas.state.defaultBackgroundColor {
                status.append("背景 RGB(\(background.r),\(background.g),\(background.b))")
            }
        }
        // Sweeping is the one tool whose progress is not visible from the curve
        // alone: the polyline shows the part already rebuilt, but not how much is
        // left, and "can I let go yet" is the only question the user has while
        // dragging. The count answers it.
        if canvas.tool == .reorder {
            if let progress = canvas.reorderProgress {
                status.append(progress.swept >= progress.total
                    ? "重排完成 \(progress.total)/\(progress.total) 点 —— 折线已按扫过顺序重建"
                    : "重排 \(progress.swept)/\(progress.total) 点 —— 继续用圈扫过剩下的点")
            } else if hasImage {
                status.append("点重排:当前曲线不到 2 个点,先取点再扫")
            }
        }
        // The grid tools set things the picture does not show: which way the scan
        // lines run, how far apart they are, and which pixels they land on. A user
        // who turned the grid a quarter turn and saw the canvas not move has no
        // way to tell a mode change from a dead menu item — the same gap the
        // reorder progress above fills. The strip's own readout cannot carry it:
        // that slot holds `间距 8px` in 58 points and a word would be clipped.
        if canvas.tool == .gridDigitize || canvas.tool == .redigitize {
            let grid = canvas.state.areaDigitizingGrid
            status.append("\(grid.axis.displayName) · 间距 \(canvas.state.gridSpacing)px"
                + " · 偏移 \(grid.phase)px")
        }
        if let extra { status.append(extra) }
        if hasUnsavedChanges { status.append("未保存") }
        if !hasImage { status.append("拖入图片也可以打开") }

        let summary = hasImage
            ? "曲线 \(lines.count) 条 · 数据点 \(pointCount)"
            : ""

        bitmap.update(step: step,
                      status: status.joined(separator: "    ·    "),
                      lineSummary: summary)

        toolbar.update(isLoadingEnabled: hasImage,
                       canExport: calibrated && pointCount > 0,
                       canUndo: canvas.canUndo,
                       canRedo: canvas.canRedo)

        // The menu names the action it would take back. Written here rather than
        // in `validateMenuItem` because this already runs on every state change
        // and the two would otherwise be a second place the history is read from.
        undoMenuItem.title = canvas.undoLabel.map { "撤销 \($0)" } ?? "撤销"
        undoMenuItem.isEnabled = canvas.canUndo
        redoMenuItem.title = canvas.redoLabel.map { "重做 \($0)" } ?? "重做"
        redoMenuItem.isEnabled = canvas.canRedo

        showsImageMenuItem.state = canvas.showsImage ? .on : .off
        // The second view of the same document is refreshed from the same place.
        // Only when it exists — opening it is the user's move, not something the
        // first edit should do on his behalf.
        if dataPlotView != nil { dataPlotView?.state = canvas.state }

        // The tick on the grid direction. Written here rather than in
        // `validateMenuItem` because this already runs on every state change and
        // two readers of the same setting is how they end up disagreeing.
        for (axis, item) in gridAxisItems {
            item.state = canvas.state.areaDigitizingGrid.axis == axis ? .on : .off
        }

        // The tick on the decimal separator, for the same reason — and read from
        // the same place the export path reads, so the tick cannot claim one
        // setting while the next file is written with the other.
        for (separator, item) in decimalSeparatorItems {
            item.state = exportDecimalSeparator == separator ? .on : .off
        }

        // Last, and deliberately: the title and the edited dot are read off the
        // state this method has just finished rebuilding the other views from, so
        // doing it here is what keeps them from describing a moment that has
        // already gone by.
        updateDocumentChrome()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法完成"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        if window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {

    /// The window's own route to the unsaved-work question, taken before the
    /// window is allowed to close. `applicationShouldTerminate` covers `⌘Q`; the
    /// two share one check so the answer cannot differ between them.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmClosingTheDocument()
    }
}

// MARK: - CanvasViewDelegate

extension AppDelegate: CanvasViewDelegate {

    func canvas(_ canvas: CanvasView, didCollectScalePoints anchors: CalibrationAnchors) {
        CalibrationSheet.present(in: window,
                                 anchors: anchors,
                                 previous: nil) { [weak self] map in
            guard let self else { return }
            if let map {
                // The sheet built the map; install it with the anchors that
                // produced it so the rules are drawn where the user clicked.
                canvas.applyCalibration(anchors: anchors,
                                        xStartValue: map.x.valueMin,
                                        xEndValue: map.x.valueMax,
                                        yStartValue: map.y.valueMin,
                                        yEndValue: map.y.valueMax,
                                        xIsLogarithmic: map.x.isLogarithmic,
                                        yIsLogarithmic: map.y.isLogarithmic)
                // Says "move the pointer back" rather than "drag the four markers"
                // because the markers are no longer sitting on the chart drawing
                // attention to themselves: they come back when the pointer
                // approaches one, and the message is the only thing that says so.
                self.refreshUI("坐标系已设置 —— 鼠标移回标记处可微调,或用「修改标定数值」改数值")
                canvas.tool = .browse
            } else {
                canvas.cancelPendingScale()
                self.refreshUI("已取消标定")
            }
        }
    }

    func canvasDidChangeState(_ canvas: CanvasView) {
        refreshUI()
    }

    /// A parameter the strip shows changed. Its own channel, because the slider
    /// reports on every frame of a drag while `refreshUI` rebuilds the data
    /// panel's two tables — and none of these numbers appears in them.
    func canvas(_ canvas: CanvasView, didChangeParameter parameter: ToolParameter, to value: Double) {
        bitmap.updateParameter(value: value)
    }

    func canvas(_ canvas: CanvasView, didFailWith message: String) {
        presentError(message)
    }

    func canvas(_ canvas: CanvasView, didRedigitize lineName: String, removed: Int, added: Int) {
        // Report both halves. "已重取" alone would hide the pass that deleted a
        // stretch and found nothing to put back, which is the one case the user
        // needs to know about.
        var report = "「\(lineName)」重取完成"
        if removed > 0 { report += " —— 删除 \(removed) 点" }
        if added > 0 { report += ",重新取到 \(added) 点" }
        refreshUI(removed > 0 || added > 0 ? report : "这一片没有变化")
    }
}

// MARK: - ToolbarDelegate

extension AppDelegate: ToolbarDelegate {

    func toolbar(_ toolbar: ToolbarView, didSelect tool: ToolMode) {
        // 标定 goes through the guard: an accidental click must not wipe an
        // existing coordinate system.
        if tool == .setScale {
            beginCalibration()
            return
        }
        // Re-selecting the tool already in hand changes nothing on screen, and a
        // click with no visible effect is indistinguishable from a broken one —
        // the same reason 适配窗口 answers even when it has nothing to do.
        //
        // 浏览 needs this most: it is the tool the window opens in, so the very
        // first click on it is always a no-op, and "浏览" reads to some users as
        // "browse for a file" rather than "pan and zoom the canvas". Echoing the
        // tool's own hint settles both questions at once.
        if canvas.tool == tool {
            refreshUI(tool.hint)
            return
        }
        canvas.tool = tool
        refreshUI()
    }

    func toolbarDidRequestUndo(_ toolbar: ToolbarView) {
        undoAction(nil)
    }

    func toolbarDidRequestRedo(_ toolbar: ToolbarView) {
        redoAction(nil)
    }

    func toolbarDidRequestCopy(_ toolbar: ToolbarView) {
        copyData(nil)
    }

    func toolbarDidRequestExport(_ toolbar: ToolbarView, from sender: NSView) {
        // The toolbar's 导出 button is the general one; 只导出当前曲线 is a menu
        // command, because the toolbar has no width left for a second button.
        presentFormatChooser(onlyActive: false)
    }

    func toolbarDidRequestFit(_ toolbar: ToolbarView) {
        let changed = canvas.zoomToFit()
        // Say something either way: a button that appears to do nothing is
        // indistinguishable from a broken one.
        refreshUI(changed ? "已适配窗口" : "已是适配状态")
    }
}

// MARK: - InfoBarDelegate

extension AppDelegate: InfoBarDelegate {

    func infoBar(_ infoBar: InfoBarView, didSetParameter parameter: ToolParameter, to value: Double) {
        // Each setter clamps to the same range the slider offers, so there is
        // nothing to guard against here.
        //
        // No status message either: the readout beside the knob is the feedback,
        // and this runs on every frame of a drag.
        canvas.setValue(value, of: parameter)
        // Round trip: the canvas is the one that clamps, so the readout is
        // rewritten from what it settled on rather than from what was asked.
        infoBar.updateParameter(value: canvas.value(of: parameter))
    }
}

// MARK: - SidebarViewDelegate

extension AppDelegate: SidebarViewDelegate {

    func sidebar(_ sidebar: SidebarView, didSelectLine id: UUID) {
        canvas.selectLine(id: id)
        refreshUI()
    }

    func sidebar(_ sidebar: SidebarView, didSetOrder order: PointOrder, for id: UUID) {
        canvas.setOrder(order, for: id)
        refreshUI("取点顺序 = \(order.displayName)")
    }

    func sidebar(_ sidebar: SidebarView, didSetVisible visible: Bool, for id: UUID) {
        canvas.setVisible(visible, for: id)
        refreshUI()
    }

    func sidebar(_ sidebar: SidebarView, didRenameLine id: UUID, to name: String) {
        canvas.renameLine(id: id, to: name)
        refreshUI()
    }

    func sidebarDidRequestAddLine(_ sidebar: SidebarView) {
        canvas.addLine()
        refreshUI("已新增曲线 —— 用「取曲线颜色」点这条曲线即可开始取点")
    }

    /// A 符号匹配 pass. Both the count and the rejections, because the rejections
    /// are what explain the count: a scatter of forty that yields three is either
    /// a chart with three symbols on it or a diameter estimate that is far out,
    /// and only these numbers tell the two apart.
    func canvas(_ canvas: CanvasView, didMatchSymbols found: Int, replacing: Int,
                rejectedSmaller: Int, rejectedLarger: Int, rejectedShape: Int) {
        var message = "符号匹配:找到 \(found) 个符号"
        if replacing > 0 { message += ",替换了原来的 \(replacing) 个点" }
        var skipped: [String] = []
        if rejectedSmaller > 0 { skipped.append("比估计小的 \(rejectedSmaller) 个") }
        if rejectedLarger > 0 { skipped.append("比估计大的 \(rejectedLarger) 个") }
        if rejectedShape > 0 { skipped.append("不像符号的 \(rejectedShape) 个") }
        if !skipped.isEmpty {
            message += " · 另有 " + skipped.joined(separator: "、")
                + " 未采用(直径 \(canvas.state.symbolDiameter)px)"
        }
        refreshUI(message)
    }

    func sidebar(_ sidebar: SidebarView, didRequestRemoveLine id: UUID) {
        canvas.removeLine(id: id)
        refreshUI("已删除曲线")
    }

    /// A coordinate typed into the point table — FR-7.2.
    ///
    /// The value is in the chart's own numbers and the canvas turns it into a
    /// pixel, because the canvas is what holds the calibration. A refusal is
    /// answered in the status line rather than with an alert: the panel has
    /// already put the old number back, so the user's next move is to try another
    /// value, and a modal to dismiss in between would be in the way. What it does
    /// need is the *reason*.
    func sidebar(_ sidebar: SidebarView, didEditPointAt row: Int,
                 axis: PointCoordinate, to value: Double) -> Bool {
        guard canvas.setCoordinate(value, of: axis, atDisplayIndex: row) else {
            refreshUI(canvas.state.calibration == nil
                ? "第 \(row + 1) 个点的像素坐标取不到这个值,已还原"
                : "该值在当前的 \(axis == .x ? "X" : "Y") 轴上没有意义(对数轴必须为正),已还原")
            return false
        }
        // No panel reload: the number the user typed is already in the cell, and
        // rebuilding the table would take them out of the row they are editing.
        refreshUI("已把第 \(row + 1) 个点的 \(axis == .x ? "X" : "Y") 改为 \(value)",
                  reloadingPanel: false)
        return true
    }

    func sidebar(_ sidebar: SidebarView, didRequestRemovePointAt row: Int) {
        refreshUI(canvas.removePoint(atDisplayIndex: row)
            ? "已删除第 \(row + 1) 个点"
            : "这一行没有对应的数据点")
    }
}
