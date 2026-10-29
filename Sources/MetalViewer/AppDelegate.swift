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

/// 右上角鼠标控制面板（ImGui 风格），可点击
final class ControlPanel: NSView {

    /// 面板动作回调，由 AppDelegate 注入
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onReset: (() -> Void)?
    var onModeChanged: ((Int) -> Void)?
    var onCycleLOD: (() -> Void)?
    var onToggleTutorial: (() -> Void)?
    var onToggleExperiment: (() -> Void)?

    private let modeSegments = NSSegmentedControl()
    private let lodButton = NSButton(title: "LOD：自动", target: nil, action: nil)
    private let tutorialButton = NSButton(title: "📘 教程", target: nil, action: nil)
    private let experimentButton = NSButton(title: "🧪 实验", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        layer?.cornerRadius = 6

        let openButton = NSButton(title: "打开模型…", target: self, action: #selector(openClicked))
        let closeButton = NSButton(title: "关闭模型", target: self, action: #selector(closeClicked))
        let resetButton = NSButton(title: "重置视角 (R)", target: self, action: #selector(resetClicked))

        modeSegments.segmentStyle = .texturedSquare
        modeSegments.segmentCount = 4
        modeSegments.setLabel("着色", forSegment: 0)
        modeSegments.setLabel("线框", forSegment: 1)
        modeSegments.setLabel("包围盒", forSegment: 2)
        modeSegments.setLabel("LOD分色", forSegment: 3)
        modeSegments.selectedSegment = 0
        modeSegments.target = self
        modeSegments.action = #selector(modeChanged(_:))

        lodButton.target = self
        lodButton.action = #selector(lodClicked)
        lodButton.title = "LOD 锁定：自动"

        tutorialButton.target = self
        tutorialButton.action = #selector(tutorialClicked)

        experimentButton.target = self
        experimentButton.action = #selector(experimentClicked)

        for button in [openButton, closeButton, resetButton, lodButton, tutorialButton, experimentButton] as [NSButton] {
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 12)
        }

        let stack = NSStackView(views: [
            makeRow([openButton, closeButton]),
            makeRow([resetButton, lodButton]),
            makeRow([tutorialButton, experimentButton]),
            modeSegments
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            modeSegments.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var lodLockTitle: String {
        get { lodButton.title }
        set { lodButton.title = newValue }
    }

    var selectedMode: Int {
        get { modeSegments.selectedSegment }
        set { modeSegments.selectedSegment = newValue }
    }

    private func makeRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func openClicked() { onOpen?() }
    @objc private func closeClicked() { onClose?() }
    @objc private func resetClicked() { onReset?() }
    @objc private func lodClicked() { onCycleLOD?() }
    @objc private func tutorialClicked() { onToggleTutorial?() }
    @objc private func experimentClicked() { onToggleExperiment?() }
    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        onModeChanged?(sender.selectedSegment)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var viewer: ViewerView!
    private var overlay: OverlayPanel!
    private var controlPanel: ControlPanel!
    private var tutorialPanel: TutorialPanel!
    private var experimentPanel: ExperimentPanel!
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

        controlPanel = ControlPanel()
        controlPanel.translatesAutoresizingMaskIntoConstraints = false
        controlPanel.onOpen = { [weak self] in self?.openModelAction() }
        controlPanel.onClose = { [weak self] in self?.closeModelAction() }
        controlPanel.onReset = { [weak self] in self?.renderer?.resetView() }
        controlPanel.onCycleLOD = { [weak self] in
            guard let self else { return }
            self.renderer?.cycleLODLock()
            self.controlPanel.lodLockTitle = "LOD 锁定：\(self.renderer?.lodLockText() ?? "自动")"
        }
        controlPanel.onModeChanged = { [weak self] raw in
            guard let mode = RenderMode(rawValue: raw) else { return }
            self?.renderer?.setRenderMode(mode)
        }
        controlPanel.onToggleTutorial = { [weak self] in
            guard let self else { return }
            self.tutorialPanel.isHidden = !self.tutorialPanel.isHidden
            self.experimentPanel.isHidden = true
        }
        controlPanel.onToggleExperiment = { [weak self] in
            guard let self else { return }
            self.experimentPanel.isHidden = !self.experimentPanel.isHidden
            self.tutorialPanel.isHidden = true
        }
        viewer.addSubview(controlPanel)
        NSLayoutConstraint.activate([
            controlPanel.trailingAnchor.constraint(equalTo: viewer.trailingAnchor, constant: -12),
            controlPanel.topAnchor.constraint(equalTo: viewer.topAnchor, constant: 12)
        ])

        tutorialPanel = TutorialPanel()
        tutorialPanel.translatesAutoresizingMaskIntoConstraints = false
        tutorialPanel.isHidden = true
        viewer.addSubview(tutorialPanel)
        NSLayoutConstraint.activate([
            tutorialPanel.trailingAnchor.constraint(equalTo: controlPanel.leadingAnchor, constant: -12),
            tutorialPanel.topAnchor.constraint(equalTo: viewer.topAnchor, constant: 12),
            tutorialPanel.bottomAnchor.constraint(equalTo: viewer.bottomAnchor, constant: -12),
            tutorialPanel.widthAnchor.constraint(equalToConstant: 560)
        ])

        experimentPanel = ExperimentPanel()
        experimentPanel.translatesAutoresizingMaskIntoConstraints = false
        experimentPanel.isHidden = true
        viewer.addSubview(experimentPanel)
        NSLayoutConstraint.activate([
            experimentPanel.trailingAnchor.constraint(equalTo: controlPanel.leadingAnchor, constant: -12),
            experimentPanel.topAnchor.constraint(equalTo: viewer.topAnchor, constant: 12),
            experimentPanel.widthAnchor.constraint(equalToConstant: 360)
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
            configureTutorial()
            configureExperiment()
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

    // MARK: 教程内容

    private func configureTutorial() {
        guard let renderer = renderer else { return }
        let syncMode: (RenderMode) -> Void = { [weak self] mode in
            renderer.setRenderMode(mode)
            self?.controlPanel.selectedMode = mode.rawValue
        }

        let lessons: [Lesson] = [
            // 1
            Lesson(
                title: "Metal 窗口与渲染循环",
                difficulty: .beginner,
                concept: "MetalViewer 用 MTKView 承载 Metal 内容。渲染循环不走系统默认的 60fps 同步，而是用 1ms 的 DispatchSourceTimer 在私有队列主动调用 draw()，并通过 displaySyncEnabled=false 解除垂直同步，所以能跑到 700+ FPS。窗口遮挡时跳过绘制省电。",
                codeBlocks: [
                    "viewer.isPaused = true\nviewer.enableSetNeedsDisplay = false\n(viewer.layer as? CAMetalLayer)?.displaySyncEnabled = false",
                    "let timer = DispatchSource.makeTimerSource(queue: renderQueue)\ntimer.schedule(deadline: .now(), repeating: .milliseconds(1))\ntimer.setEventHandler {\n    guard self.isWindowVisible else { return }\n    viewer.draw()\n}"
                ],
                keyPoints: [
                    "MTKView 是 Metal 内容的载体，本质是一个 NSView",
                    "displaySyncEnabled=false 解除垂直同步，才能跑满 GPU",
                    "渲染在私有队列，不阻塞主线程 UI"
                ],
                quiz: Quiz(question: "解除垂直同步的关键代码是？",
                           options: ["viewer.isPaused = true", "(layer as? CAMetalLayer)?.displaySyncEnabled = false", "viewer.enableSetNeedsDisplay = false"],
                           answer: 1),
                action: { renderer.resetView() }
            ),
            // 2
            Lesson(
                title: "GLB 容器结构",
                difficulty: .beginner,
                concept: "GLB 是 glTF 的二进制打包：12 字节头部 + JSON chunk + BIN chunk。头部魔数是 \"glTF\"，版本为 2。JSON 描述场景/节点/网格/材质/accessor，BIN 存原始顶点与索引数据。",
                codeBlocks: [
                    "// 头部 12 字节：magic(4) + version(4) + length(4)\nlet magic = String(bytes: header, encoding: .ascii) // \"glTF\"\nlet version = header.load(as: UInt32.self)            // 2",
                    "// 遍历 chunk，区分 JSON(0x4E4F534A) 与 BIN(0x004E4942)\nswitch chunkType {\ncase 0x4E4F534A: jsonChunk = data[start..<end]\ncase 0x004E4942: binStart = start\n}"
                ],
                keyPoints: [
                    "glTF 是文本格式，GLB 是它的单文件二进制打包",
                    "accessor 是「从 BIN 取什么数据」的描述符",
                    "节点用矩阵或 TRS（平移/旋转/缩放）描述变换"
                ],
                quiz: Quiz(question: "GLB 文件的魔数（前 4 字节）是？",
                           options: ["glTF", "GLB2", "glTF2", "BIN "],
                           answer: 0),
                action: nil
            ),
            // 3
            Lesson(
                title: "场景图与世界矩阵",
                difficulty: .beginner,
                concept: "glTF 场景是一棵树。每个节点有自己的局部变换（TRS 或 4×4 矩阵）。加载时深度优先遍历，把父节点的世界矩阵与当前节点的局部矩阵相乘，得到该节点所有网格的世界坐标。",
                codeBlocks: [
                    "// 深度优先遍历，累积世界矩阵\nvar stack: [(node: Int, parent: float4x4)] = roots.map { ($0, .identity) }\nwhile let (node, parent) = stack.popLast() {\n    let world = parent * localMatrix(of: node)\n    for child in node.children ?? [] {\n        stack.append((child, world))\n    }\n    // 用 world 矩阵变换该节点的 mesh\n}",
                    "// 局部矩阵：优先用 matrix 字段，否则由 translation/rotation/scale 合成\nfunc localMatrix(of node) -> float4x4 {\n    if let m = node.matrix { return float4x4(m) }\n    return translation * rotation * scale\n}"
                ],
                keyPoints: [
                    "世界矩阵 = 父世界矩阵 × 自身局部矩阵",
                    "TRS 合成顺序：T × R × S（先缩放再旋转再平移）",
                    "只有 mesh 节点的 primitive 才会变成 DrawItem"
                ],
                quiz: Quiz(question: "节点世界矩阵如何计算？",
                           options: ["自身局部矩阵", "父世界矩阵 × 自身局部矩阵", "自身局部矩阵 × 父世界矩阵", "父局部矩阵 × 自身矩阵"],
                           answer: 1),
                action: { renderer.resetView() }
            ),
            // 4
            Lesson(
                title: "渲染管线与着色器",
                difficulty: .intermediate,
                concept: "Metal 管线由 顶点着色器 + 片元着色器 组成。本项目用运行期编译 .metal 源码（makeLibrary(source:)），避免 SwiftPM 编译 .metal 的麻烦。顶点着色器把局部坐标乘 model × viewProjection 到裁剪空间，片元着色器做 Blinn-Phong 光照。",
                codeBlocks: [
                    "// 运行期编译 Metal Shading Language\nlet library = try device.makeLibrary(source: ShaderSource.metal)\nlet vertexFunction = library.makeFunction(name: \"vertex_main\")\nlet fragmentFunction = library.makeFunction(name: \"fragment_main\")",
                    "vertex VertexOut vertex_main(VertexIn in [[stage_in]],\n                             constant Uniforms &u [[buffer(2)]]) {\n    float4 world = u.model * float4(in.position, 1.0);\n    out.position = u.viewProjection * world;\n    out.normal = (u.normalMatrix * float4(in.normal, 0)).xyz;\n    return out;\n}"
                ],
                keyPoints: [
                    "[[stage_in]] 表示顶点输入由顶点描述符组装",
                    "model 矩阵把局部坐标变世界坐标，viewProjection 变裁剪空间",
                    "Uniforms 放在 buffer(2)，同时绑定到顶点和片元阶段"
                ],
                quiz: Quiz(question: "顶点着色器输出的 position 应该在哪个空间？",
                           options: ["局部空间", "世界空间", "裁剪空间 (NDC)", "屏幕空间"],
                           answer: 2),
                action: { syncMode(.shaded) }
            ),
            // 5
            Lesson(
                title: "Blinn-Phong 光照",
                difficulty: .intermediate,
                concept: "片元着色器里实现 Blinn-Phong：漫反射 = N·L，高光 = (N·H)^shininess。法线用 normalMatrix（model 上 3×3 的逆转置）变换，避免非均匀缩放扭曲法线。双面材质通过 frontFacing 翻转法线。",
                codeBlocks: [
                    "float3 n = normalize(in.normal);\nif (!frontFacing) { n = -n; }   // 双面材质\n\nfloat3 lightDir = normalize(u.lightDirection);\nfloat3 viewDir = normalize(u.cameraPosition - in.worldPosition);\nfloat3 halfVec = normalize(lightDir + viewDir);\n\nfloat ndl  = max(dot(n, lightDir), 0.0);\nfloat spec = pow(max(dot(n, halfVec), 0.0), 40.0) * 0.15;",
                    "// 法线矩阵 = model 上 3×3 的逆转置\nlet inverseTranspose = upper.inverse.transpose"
                ],
                keyPoints: [
                    "Blinn-Phong 比 Phong 多一个半角向量 H，高光更稳定",
                    "法线必须用逆转置矩阵变换，否则缩放会让法线方向错",
                    "双面材质靠 frontFacing 把背向法线翻过来"
                ],
                quiz: Quiz(question: "法线矩阵是 model 矩阵上 3×3 部分的什么？",
                           options: ["转置", "逆", "逆转置", "转置逆"],
                           answer: 2),
                action: { syncMode(.shaded) }
            ),
            // 6
            Lesson(
                title: "平滑法线生成",
                difficulty: .intermediate,
                concept: "glTF 模型可能没有法线。这时需要自动生成：遍历每个三角形，把叉积（长度 = 2×面积）加到三个顶点的法线累积上，最后归一化。面积加权让大三角形对法线影响更大。",
                codeBlocks: [
                    "var normals = [SIMD3<Float>](repeating: .zero, count: vertexCount)\nfor t in stride(from: 0, to: indices.count, by: 3) {\n    let (a, b, c) = (indices[t], indices[t+1], indices[t+2])\n    let edge1 = pos[b] - pos[a]\n    let edge2 = pos[c] - pos[a]\n    let faceNormal = simd_cross(edge1, edge2)   // 长度 ∝ 面积\n    normals[a] += faceNormal\n    normals[b] += faceNormal\n    normals[c] += faceNormal\n}\nfor i in normals.indices { normals[i] = simd_normalize(normals[i]) }"
                ],
                keyPoints: [
                    "叉积 simd_cross 的长度等于 2 倍三角形面积，天然面积加权",
                    "共享顶点的三角形都会贡献法线，形成平滑过渡",
                    "硬边模型应该直接用 glTF 提供的法线，不要自动平滑"
                ],
                quiz: Quiz(question: "面积加权平滑法线中，三角形贡献的法线向量是？",
                           options: ["两邻边的点积", "两邻边的叉积", "两邻边的和", "两邻边的平均"],
                           answer: 1),
                action: { syncMode(.shaded) }
            ),
            // 7
            Lesson(
                title: "轨道相机",
                difficulty: .beginner,
                concept: "相机用球坐标：target（目标点）、distance（距离）、yaw（偏航）、pitch（俯仰）。由这四个量反推 eye 位置，再用 lookAt 生成 view 矩阵。左键改 yaw/pitch，右键平移 target，滚轮改 distance。",
                codeBlocks: [
                    "var eye = target + distance * SIMD3(\n    cos(pitch) * sin(yaw),\n    sin(pitch),\n    cos(pitch) * cos(yaw)\n)\nlet view = lookAt(eye: eye, center: target, up: SIMD3(0, 1, 0))",
                    "// Metal 的 NDC z 范围是 [0, 1]，注意透视矩阵写法\nstatic func perspective(fovY, aspect, near, far) -> float4x4 {\n    let z = far / (near - far)\n    return float4x4(columns: (\n        SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),\n        SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)\n    ))\n}"
                ],
                keyPoints: [
                    "球坐标比欧拉角更适合轨道相机，避免万向锁",
                    "Metal 的 NDC z ∈ [0,1]，OpenGL 是 [-1,1]",
                    "near 不能太小，否则深度精度会爆炸"
                ],
                quiz: Quiz(question: "Metal 的 NDC 深度范围是？",
                           options: ["[-1, 1]", "[0, 1]", "[0, ∞)", "[-1, 0]"],
                           answer: 1),
                action: { renderer.resetView() }
            ),
            // 8
            Lesson(
                title: "三角面线框模式",
                difficulty: .beginner,
                concept: "线框不需要重新生成几何，只要把 Metal 的填充模式从 .fill 改成 .lines，GPU 就会把每个三角形的三条边画出来。三角面越多，线越密。",
                codeBlocks: [
                    "encoder.setTriangleFillMode(mode == .wireframe ? .lines : .fill)\nencoder.drawIndexedPrimitives(type: .triangle, ...)"
                ],
                keyPoints: [
                    ".lines 模式下三角形自动被画成三条边线",
                    "不需要修改任何顶点/索引数据",
                    "可以用来检查模型的三角面密度分布"
                ],
                quiz: Quiz(question: "线框模式通过修改什么实现？",
                           options: ["重新生成索引", "setTriangleFillMode(.lines)", "换一个着色器", "修改顶点数据"],
                           answer: 1),
                action: { syncMode(.wireframe) }
            ),
            // 9
            Lesson(
                title: "包围盒可视化",
                difficulty: .intermediate,
                concept: "每个网格有一个世界空间 AABB（轴对齐包围盒）。我们预先创建一个单位立方体 (0..1) 的 buffer，对每个网格用 平移(min) × 缩放(size) 的矩阵变换，就能画出任意 AABB 的 12 条棱。",
                codeBlocks: [
                    "var boxModel = matrix_identity_float4x4\nboxModel.columns.0.x = boxSize.x\nboxModel.columns.1.y = boxSize.y\nboxModel.columns.2.z = boxSize.z\nboxModel.columns.3 = SIMD4(min.x, min.y, min.z, 1)\n\ndrawIndexedPrimitives(type: .line, indexCount: 24, ...)"
                ],
                keyPoints: [
                    "AABB 只用 min/max 两个点定义，计算极快",
                    "用单位立方体 + 缩放矩阵复用同一份顶点数据",
                    "包围盒是视锥剔除、碰撞检测的基础"
                ],
                quiz: Quiz(question: "画任意 AABB 复用了什么几何？",
                           options: ["每个 mesh 自己的顶点", "一个单位立方体 buffer", "球", "平面"],
                           answer: 1),
                action: { syncMode(.boundingBox) }
            ),
            // 10
            Lesson(
                title: "顶点聚类 LOD 简化",
                difficulty: .advanced,
                concept: "把模型空间划成格子（cellSize = 对角线/32 用于 LOD1，/16 用于 LOD2），同格的所有顶点合并成一个（位置平均、法线归一化）。重建三角形时丢弃退化、零面积、重复三角形。格子越大，合并越狠。",
                codeBlocks: [
                    "let cellSize = diagonal / 32.0   // LOD1\n// 对每个顶点计算它落在哪个格子\nlet cell = SIMD3<Int>(\n    Int(floor(pos.x / cellSize)),\n    Int(floor(pos.y / cellSize)),\n    Int(floor(pos.z / cellSize))\n)\n// 同格顶点：位置取平均、法线相加后归一化",
                    "// 重建索引时剔除退化三角形\nlet area = simd_length(simd_cross(b - a, c - a))\nif area < 1e-8 { continue }"
                ],
                keyPoints: [
                    "顶点聚类不保证拓扑，但实现简单、速度快",
                    "cellSize 取 包围盒最短边 × 0.4 防止薄板塌陷",
                    "法线平均后可能为零（正反相消），需要回退到首顶点法线"
                ],
                quiz: Quiz(question: "顶点聚类中，cellSize 越大，LOD 越？",
                           options: ["越精细", "越粗糙", "不变", "越精确"],
                           answer: 1),
                action: { syncMode(.lodColor) }
            ),
            // 11
            Lesson(
                title: "LOD 像素半径选档",
                difficulty: .advanced,
                concept: "每帧把每个网格的世界半径换算成屏幕像素半径，再按阈值选档：>160px 用 LOD0，60–160px 用 LOD1，2–60px 用 LOD2，<2px 直接剔除不画。这样远处用粗网格、近处用细网格，视觉无损但大幅省 GPU。",
                codeBlocks: [
                    "let pixelsPerUnit = viewportHeight / (2 * tan(fov/2))\nlet pixelRadius = radiusWorld * pixelsPerUnit / distance\n\nlet lod = pixelRadius > 160 ? 0\n        : pixelRadius > 60  ? 1\n        : pixelRadius > 2   ? 2\n        : -1   // 剔除"
                ],
                keyPoints: [
                    "像素半径 = 世界半径 × (视口高 / 2tan(fov/2)) / 距离",
                    "选档用屏幕像素而非世界距离，和视角无关",
                    "<2px 的物体肉眼几乎看不到，直接剔除最划算"
                ],
                quiz: Quiz(question: "一个世界半径 1 的物体，相机距离 10，视口高 800，fov=45°，像素半径约？（2tan22.5°≈0.828）",
                           options: ["约 10px", "约 96px", "约 480px", "约 800px"],
                           answer: 1),
                action: { syncMode(.lodColor) }
            ),
            // 12
            Lesson(
                title: "Hysteresis 防抖",
                difficulty: .advanced,
                concept: "如果直接按阈值选档，物体在阈值附近微小移动会导致档位来回跳变，画面闪烁。解决方案：升档时阈值 ×1.2（要明显变大才升档），降档时阈值 ×0.8（要明显变小才降档），形成一个缓冲带。",
                codeBlocks: [
                    "// 降档（细节减少）：半径要低于阈值 ×0.8 才降\nwhile lod < 2, pixelRadius < bounds[lod] * 0.8 {\n    lod += 1\n}\n// 升档（细节增加）：半径要超过阈值 ×1.2 才升\nwhile lod > 0, pixelRadius > bounds[lod - 1] * 1.2 {\n    lod -= 1\n}"
                ],
                keyPoints: [
                    "hysteresis = 滞后，类似施密特触发器",
                    "升档系数 >1，降档系数 <1，两者之间是缓冲带",
                    "每个 DrawItem 记录 currentLOD，跨帧保持状态"
                ],
                quiz: Quiz(question: "hysteresis 的主要作用是？",
                           options: ["提高帧率", "防止档位在阈值附近来回跳变", "减少内存", "提升画质"],
                           answer: 1),
                action: { syncMode(.lodColor) }
            )
        ]
        tutorialPanel.configure(lessons: lessons)
    }

    // MARK: 实验面板绑定

    private func configureExperiment() {
        guard let renderer = renderer else { return }
        experimentPanel.onFOVChanged = { renderer.setFOVDegrees($0) }
        experimentPanel.onLightChanged = { renderer.setLightDirection($0) }
        experimentPanel.onLODChanged = { renderer.setLODThresholds(bounds: $0, cullRadius: $1) }
        experimentPanel.onReset = { renderer.resetView() }
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
