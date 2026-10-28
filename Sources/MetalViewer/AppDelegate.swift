import AppKit
import MetalKit
import QuartzCore
import UniformTypeIdentifiers

/// 左上角调试信息浮层，不拦截鼠标事件
final class OverlayPanel: NSView {

    private let label = NSTextField(labelWithString: "")

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        layer?.cornerRadius = 6

        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var viewer: ViewerView!
    private var overlay: OverlayPanel!
    private var renderer: Renderer?
    private var statsTimer: Timer?
    private var renderTimer: DispatchSourceTimer?
    private let renderQueue = DispatchQueue(label: "MetalViewer.render", qos: .userInteractive)
    private var device: MTLDevice!
    private var fileName = ""
    private var loadSeconds: Double = 0
    private var lodSeconds: Double = 0
    private var isWindowVisible = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        guard let device = MTLCreateSystemDefaultDevice() else {
            let alert = NSAlert()
            alert.messageText = "无法创建 Metal 设备"
            alert.informativeText = "当前设备不支持 Metal，无法渲染。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.device = device

        let contentSize = NSSize(width: 1280, height: 800)
        viewer = ViewerView(frame: NSRect(origin: .zero, size: contentSize), device: device)
        viewer.colorPixelFormat = .bgra8Unorm_srgb
        viewer.depthStencilPixelFormat = .depth32Float
        viewer.clearColor = MTLClearColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1)
        (viewer.layer as? CAMetalLayer)?.displaySyncEnabled = false
        viewer.isPaused = true
        viewer.enableSetNeedsDisplay = false
        viewer.autoResizeDrawable = true

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Metal Viewer"
        window.contentView = viewer
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(viewer)

        overlay = OverlayPanel()
        overlay.text = "准备中…"
        overlay.translatesAutoresizingMaskIntoConstraints = false
        viewer.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: viewer.leadingAnchor, constant: 12),
            overlay.topAnchor.constraint(equalTo: viewer.topAnchor, constant: 12),
            overlay.widthAnchor.constraint(equalToConstant: 560),
            overlay.heightAnchor.constraint(equalToConstant: 200)
        ])

        NSApp.activate(ignoringOtherApps: true)
        loadModel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: 加载

    private func loadModel() {
        let argument = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "a.glb"
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = URL(fileURLWithPath: argument, relativeTo: workingDirectory).standardizedFileURL
        loadModel(url: url)
    }

    private func loadModel(url: URL) {
        fileName = url.lastPathComponent
        overlay.text = "正在加载 \(fileName) …"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            do {
                var model = try GLBLoader.load(url: url)
                let loadSeconds = CFAbsoluteTimeGetCurrent() - started
                DispatchQueue.main.async {
                    self?.overlay.text = "正在生成 LOD \(self?.fileName ?? "") …"
                }
                let lodStarted = CFAbsoluteTimeGetCurrent()
                LODGenerator.generate(model: &model)
                let lodSeconds = CFAbsoluteTimeGetCurrent() - lodStarted
                DispatchQueue.main.async {
                    self?.install(model: model, seconds: loadSeconds, lodSeconds: lodSeconds)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.overlay.text = "加载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func install(model: LoadedModel, seconds: Double, lodSeconds: Double) {
        loadSeconds = seconds
        self.lodSeconds = lodSeconds
        do {
            let renderer = try Renderer(
                device: device,
                colorPixelFormat: viewer.colorPixelFormat,
                depthPixelFormat: viewer.depthStencilPixelFormat
            )
            renderer.setModel(model)
            renderer.frameModel()

            self.renderer = renderer
            viewer.renderer = renderer
            viewer.delegate = renderer
            window.makeFirstResponder(viewer)
            window.title = "Metal Viewer — \(fileName)"
            overlay.text = renderer.debugText(fileName: fileName, loadSeconds: seconds, lodSeconds: lodSeconds)
            startRenderLoop()
            startStatsTimer()
        } catch {
            overlay.text = "渲染器初始化失败：\(error.localizedDescription)"
        }
    }

    private func startRenderLoop() {
        renderTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, let viewer = self.viewer, self.isWindowVisible else { return }
            viewer.draw()
        }
        timer.resume()
        renderTimer = timer
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let renderer = self.renderer else { return }
            self.isWindowVisible = self.window.occlusionState.contains(.visible)
            self.overlay.text = renderer.debugText(
                fileName: self.fileName,
                loadSeconds: self.loadSeconds,
                lodSeconds: self.lodSeconds
            )
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    // MARK: 菜单

    @objc private func openModelAction() {
        let panel = NSOpenPanel()
        panel.title = "打开模型"
        panel.allowedContentTypes = [UTType(filenameExtension: "glb")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadModel(url: url)
    }

    @objc private func closeModelAction() {
        renderer?.closeModel()
        fileName = ""
        window.title = "Metal Viewer"
        overlay.text = "未加载模型 · ⌘O 打开"
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit MetalViewer",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "打开模型…",
            action: #selector(openModelAction),
            keyEquivalent: "o"
        )
        fileMenu.addItem(
            withTitle: "关闭模型",
            action: #selector(closeModelAction),
            keyEquivalent: "w"
        )
        fileMenuItem.submenu = fileMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let modes: [(String, RenderMode, String)] = [
            ("着色", .shaded, "1"),
            ("线框", .wireframe, "2"),
            ("包围盒", .boundingBox, "3"),
            ("LOD 分色", .lodColor, "4")
        ]
        for (title, mode, key) in modes {
            let item = NSMenuItem(title: title, action: #selector(renderModeAction(_:)), keyEquivalent: key)
            item.representedObject = mode.rawValue
            viewMenu.addItem(item)
        }
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func renderModeAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let mode = RenderMode(rawValue: raw) else { return }
        renderer?.setRenderMode(mode)
    }
}
