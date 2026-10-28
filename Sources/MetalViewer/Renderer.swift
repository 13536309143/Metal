import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

// MARK: - 着色器（运行期编译，避免 SwiftPM 编译 .metal 的限制）

enum ShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 model;
        float4x4 viewProjection;
        float4x4 normalMatrix;
        float4  baseColor;
        float3  lightDirection;
        float3  cameraPosition;
    };

    struct VertexIn {
        float3 position [[attribute(0)]];
        float3 normal   [[attribute(1)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float3 normal;
        float3 worldPosition;
    };

    vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                                 constant Uniforms &u [[buffer(2)]]) {
        float4 world = u.model * float4(in.position, 1.0);
        VertexOut out;
        out.position = u.viewProjection * world;
        out.normal = (u.normalMatrix * float4(in.normal, 0.0)).xyz;
        out.worldPosition = world.xyz;
        return out;
    }

    fragment float4 fragment_main(VertexOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(2)]],
                                  bool frontFacing [[front_facing]]) {
        float3 n = normalize(in.normal);
        if (!frontFacing) { n = -n; }

        float3 lightDir = normalize(u.lightDirection);
        float3 viewDir = normalize(u.cameraPosition - in.worldPosition);
        float3 halfVec = normalize(lightDir + viewDir);

        float ndl  = max(dot(n, lightDir), 0.0);
        float spec = pow(max(dot(n, halfVec), 0.0), 40.0) * 0.15;
        float rim  = pow(1.0 - max(dot(n, viewDir), 0.0), 4.0) * 0.06;

        float3 base  = u.baseColor.rgb;
        float3 color = base * (0.25 + 0.75 * ndl) + spec + rim;
        return float4(color, 1.0);
    }
    """
}

// MARK: - Uniforms（布局必须与 MSL 中的 Uniforms 完全一致）

struct ShaderUniforms {
    var model: simd_float4x4
    var viewProjection: simd_float4x4
    var normalMatrix: simd_float4x4
    var baseColor: SIMD4<Float>
    var lightDirection: SIMD3<Float>
    var cameraPosition: SIMD3<Float>
}

// MARK: - 矩阵工具

enum Matrix {
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(center - eye)
        let right = simd_normalize(simd_cross(forward, up))
        let trueUp = simd_cross(right, forward)
        return simd_float4x4(columns: (
            SIMD4<Float>(right.x, trueUp.x, -forward.x, 0),
            SIMD4<Float>(right.y, trueUp.y, -forward.y, 0),
            SIMD4<Float>(right.z, trueUp.z, -forward.z, 0),
            SIMD4<Float>(-simd_dot(right, eye), -simd_dot(trueUp, eye), simd_dot(forward, eye), 1)
        ))
    }

    /// Metal 的裁剪空间深度范围为 [0, 1]
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / max(aspect, 0.0001)
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        ))
    }

    static func normalMatrix(from model: simd_float4x4) -> simd_float4x4 {
        let upper = simd_float3x3(columns: (
            SIMD3<Float>(model.columns.0.x, model.columns.0.y, model.columns.0.z),
            SIMD3<Float>(model.columns.1.x, model.columns.1.y, model.columns.1.z),
            SIMD3<Float>(model.columns.2.x, model.columns.2.y, model.columns.2.z)
        ))
        let determinant = simd_determinant(upper)
        guard abs(determinant) > 1e-12 else { return matrix_identity_float4x4 }
        let inverseTranspose = upper.inverse.transpose
        return simd_float4x4(columns: (
            SIMD4<Float>(inverseTranspose.columns.0, 0),
            SIMD4<Float>(inverseTranspose.columns.1, 0),
            SIMD4<Float>(inverseTranspose.columns.2, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }
}

// MARK: - 轨道相机

struct OrbitCamera {
    var target = SIMD3<Float>(repeating: 0)
    var distance: Float = 5
    var yaw: Float = 0.65
    var pitch: Float = 0.35
    var fov: Float = 45 * Float.pi / 180
    var sceneRadius: Float = 1
    var minDistance: Float = 0.01
    var maxDistance: Float = 1000

    var eye: SIMD3<Float> {
        target + distance * SIMD3<Float>(
            cos(pitch) * sin(yaw),
            sin(pitch),
            cos(pitch) * cos(yaw)
        )
    }

    mutating func orbit(dx: CGFloat, dy: CGFloat) {
        yaw -= Float(dx) * 0.005
        pitch += Float(dy) * 0.005
        pitch = min(max(pitch, -1.5), 1.5)
    }

    mutating func pan(dx: CGFloat, dy: CGFloat) {
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_cross(right, forward)
        let speed = distance * 0.0015
        target += right * (-Float(dx) * speed) + up * (Float(dy) * speed)
    }

    mutating func zoom(delta: Float) {
        distance *= exp(-delta * 0.05)
        distance = min(max(distance, minDistance), maxDistance)
    }

    mutating func frame(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>) {
        let center = (boundsMin + boundsMax) * 0.5
        let radius = max(simd_length(boundsMax - boundsMin) * 0.5, 0.001)
        sceneRadius = radius
        target = center
        distance = radius / sin(fov * 0.5) * 1.1
        minDistance = radius * 0.02
        maxDistance = radius * 30
    }

    func viewMatrix() -> simd_float4x4 {
        Matrix.lookAt(eye: eye, center: target, up: SIMD3<Float>(0, 1, 0))
    }

    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        let near = max(distance * 0.005, sceneRadius * 0.001)
        let far = distance + sceneRadius * 10
        return Matrix.perspective(fovY: fov, aspect: aspect, near: near, far: far)
    }
}

// MARK: - 渲染器

enum RendererError: LocalizedError {
    case noCommandQueue
    case shaderFunctionMissing
    case pipelineFailure(String)

    var errorDescription: String? {
        switch self {
        case .noCommandQueue: return "无法创建 Metal 命令队列"
        case .shaderFunctionMissing: return "着色器函数缺失"
        case .pipelineFailure(let reason): return "渲染管线创建失败：\(reason)"
        }
    }
}

// MARK: - 渲染模式

enum RenderMode: Int, CaseIterable {
    case shaded = 0     // 材质着色
    case wireframe      // 三角面线框
    case boundingBox    // 包围盒
    case lodColor       // 按 LOD 档位分色

    var title: String { ["着色", "线框", "包围盒", "LOD 分色"][rawValue] }
    var next: RenderMode { RenderMode(rawValue: (rawValue + 1) % RenderMode.allCases.count)! }
}

final class Renderer: NSObject, MTKViewDelegate {

    private struct LODLevel {
        let positionBuffer: MTLBuffer
        let normalBuffer: MTLBuffer
        let indexBuffer: MTLBuffer
        let indexCount: Int
    }

    private final class DrawItem {
        let lods: [LODLevel]        // 依次为 LOD0 / LOD1 / LOD2
        let color: SIMD4<Float>
        let model: simd_float4x4
        let normalMatrix: simd_float4x4
        let doubleSided: Bool
        let centerWorld: SIMD3<Float>
        let radiusWorld: Float
        let boundsMinWorld: SIMD3<Float>
        let boundsMaxWorld: SIMD3<Float>
        /// 跨帧保留，用于 LOD hysteresis
        var currentLOD: Int

        init(lods: [LODLevel],
             color: SIMD4<Float>,
             model: simd_float4x4,
             normalMatrix: simd_float4x4,
             doubleSided: Bool,
             centerWorld: SIMD3<Float>,
             radiusWorld: Float,
             boundsMinWorld: SIMD3<Float>,
             boundsMaxWorld: SIMD3<Float>) {
            self.lods = lods
            self.color = color
            self.model = model
            self.normalMatrix = normalMatrix
            self.doubleSided = doubleSided
            self.centerWorld = centerWorld
            self.radiusWorld = radiusWorld
            self.boundsMinWorld = boundsMinWorld
            self.boundsMaxWorld = boundsMaxWorld
            self.currentLOD = 0
        }
    }

    /// 每帧绘制统计（供浮层显示）
    private struct FrameStats {
        var meshCount = 0
        var triangleCount = 0
        var culledCount = 0
        var lodCounts = [0, 0, 0]
        var lodTriangles = [0, 0, 0]
    }

    /// LOD 画面像素半径阈值：bounds[i] 是 LODi 与 LOD(i+1) 的分界
    private enum LODThreshold {
        static let bounds: [Float] = [160, 60]
        static let cullRadius: Float = 2
        static let hysteresisUp: Float = 1.2     // 升档（细节增加）需越过阈值 ×1.2
        static let hysteresisDown: Float = 0.8   // 降档（细节减少）需低于阈值 ×0.8
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    private var items: [DrawItem] = []
    private var boundsMin = SIMD3<Float>(repeating: 0)
    private var boundsMax = SIMD3<Float>(repeating: 0)
    private var triangleCount = 0
    private var vertexCount = 0

    private var camera = OrbitCamera()
    private let cameraLock = NSLock()
    private var lastFrameTime: CFTimeInterval = 0
    private var smoothedFPS: Double = 0

    /// 保护锁定档位与统计快照（渲染线程写、主线程读）
    private let stateLock = NSLock()
    private var lockedLOD: Int?
    private var renderMode: RenderMode = .shaded
    private var lastStats = FrameStats()

    /// 包围盒线框渲染资源
    private var linePipelineState: MTLRenderPipelineState!
    private var boxVertexBuffer: MTLBuffer!
    private var boxNormalBuffer: MTLBuffer!
    private var boxIndexBuffer: MTLBuffer!

    init(device: MTLDevice, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat) throws {
        guard let queue = device.makeCommandQueue() else { throw RendererError.noCommandQueue }

        let library = try device.makeLibrary(source: ShaderSource.metal, options: nil)
        guard let vertexFunction = library.makeFunction(name: "vertex_main"),
              let fragmentFunction = library.makeFunction(name: "fragment_main") else {
            throw RendererError.shaderFunctionMissing
        }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = 0
        vertexDescriptor.attributes[1].bufferIndex = 1
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.stride * 3
        vertexDescriptor.layouts[1].stride = MemoryLayout<Float>.stride * 3

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = depthPixelFormat

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            throw RendererError.pipelineFailure(error.localizedDescription)
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw RendererError.pipelineFailure("深度模板状态创建失败")
        }
        self.depthState = depthState

        // 包围盒线框管线：复用同一组着色器
        let lineDescriptor = MTLRenderPipelineDescriptor()
        lineDescriptor.vertexFunction = vertexFunction
        lineDescriptor.fragmentFunction = fragmentFunction
        lineDescriptor.vertexDescriptor = vertexDescriptor
        lineDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        lineDescriptor.depthAttachmentPixelFormat = depthPixelFormat
        do {
            self.linePipelineState = try device.makeRenderPipelineState(descriptor: lineDescriptor)
        } catch {
            throw RendererError.pipelineFailure(error.localizedDescription)
        }

        // 单位立方体（0..1），12 条边 = 24 个线索引
        let boxVertices: [Float] = [
            0, 0, 0,  1, 0, 0,  1, 1, 0,  0, 1, 0,
            0, 0, 1,  1, 0, 1,  1, 1, 1,  0, 1, 1
        ]
        let boxNormals = [Float](repeating: 0, count: 24)
        let boxIndices: [UInt32] = [
            0, 1, 1, 2, 2, 3, 3, 0,
            4, 5, 5, 6, 6, 7, 7, 4,
            0, 4, 1, 5, 2, 6, 3, 7
        ]
        self.boxVertexBuffer = device.makeBuffer(bytes: boxVertices, length: boxVertices.count * 4, options: .storageModeShared)
        self.boxNormalBuffer = device.makeBuffer(bytes: boxNormals, length: boxNormals.count * 4, options: .storageModeShared)
        self.boxIndexBuffer = device.makeBuffer(bytes: boxIndices, length: boxIndices.count * 4, options: .storageModeShared)

        self.device = device
        self.commandQueue = queue
        super.init()
    }

    // MARK: 数据上传

    func setModel(_ model: LoadedModel) {
        items.removeAll(keepingCapacity: true)

        for primitive in model.primitives {
            guard !primitive.indices.isEmpty, !primitive.positions.isEmpty else { continue }

            // LODGenerator 未提供数据时退化为只画原始网格
            let meshes = primitive.lods.isEmpty
                ? [LODMesh(positions: primitive.positions, normals: primitive.normals, indices: primitive.indices)]
                : primitive.lods

            var levels: [LODLevel] = []
            for mesh in meshes.prefix(3) {
                guard let level = makeLevel(mesh) else { break }
                levels.append(level)
            }
            guard let firstLevel = levels.first else { continue }

            // 简化级别不比上一级更省时直接复用上一级，保证档位单调
            if levels.count > 1, levels[1].indexCount >= firstLevel.indexCount {
                levels[1] = firstLevel
            }
            if levels.count > 2, levels[2].indexCount >= levels[1].indexCount {
                levels[2] = levels[1]
            }
            while levels.count < 3 {
                levels.append(levels[levels.count - 1])
            }

            // 世界空间包围球，用于换算屏幕像素半径
            var worldMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var worldMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for corner in Self.corners(of: primitive.localBoundsMin, primitive.localBoundsMax) {
                let transformed = primitive.worldMatrix * SIMD4<Float>(corner, 1)
                let point = SIMD3<Float>(transformed.x, transformed.y, transformed.z)
                worldMin = simd_min(worldMin, point)
                worldMax = simd_max(worldMax, point)
            }

            items.append(DrawItem(
                lods: levels,
                color: primitive.color,
                model: primitive.worldMatrix,
                normalMatrix: Matrix.normalMatrix(from: primitive.worldMatrix),
                doubleSided: primitive.doubleSided,
                centerWorld: (worldMin + worldMax) * 0.5,
                radiusWorld: max(simd_length(worldMax - worldMin) * 0.5, 1e-5),
                boundsMinWorld: worldMin,
                boundsMaxWorld: worldMax
            ))
        }

        // 单面材质先画，双面后画，减少剔除状态切换
        items.sort { !$0.doubleSided && $1.doubleSided }

        boundsMin = model.boundsMin
        boundsMax = model.boundsMax
        triangleCount = model.triangleCount
        vertexCount = model.vertexCount
    }

    private func makeLevel(_ mesh: LODMesh) -> LODLevel? {
        guard !mesh.indices.isEmpty,
              mesh.positions.count >= 9,
              mesh.normals.count == mesh.positions.count else { return nil }

        let positionBytes = mesh.positions.count * MemoryLayout<Float>.stride
        let indexBytes = mesh.indices.count * MemoryLayout<UInt32>.stride
        guard let positionBuffer = device.makeBuffer(bytes: mesh.positions, length: positionBytes, options: .storageModeShared),
              let normalBuffer = device.makeBuffer(bytes: mesh.normals, length: positionBytes, options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: mesh.indices, length: indexBytes, options: .storageModeShared) else {
            return nil
        }
        return LODLevel(
            positionBuffer: positionBuffer,
            normalBuffer: normalBuffer,
            indexBuffer: indexBuffer,
            indexCount: mesh.indices.count
        )
    }

    func frameModel() {
        withCamera { camera in
            camera.frame(boundsMin: boundsMin, boundsMax: boundsMax)
            camera.yaw = 0.65
            camera.pitch = 0.35
        }
    }

    private func withCamera(_ body: (inout OrbitCamera) -> Void) {
        cameraLock.lock()
        defer { cameraLock.unlock() }
        body(&camera)
    }

    private func cameraSnapshot() -> OrbitCamera {
        cameraLock.lock()
        defer { cameraLock.unlock() }
        return camera
    }

    // MARK: 交互

    func orbit(dx: CGFloat, dy: CGFloat) {
        withCamera { $0.orbit(dx: dx, dy: dy) }
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        withCamera { $0.pan(dx: dx, dy: dy) }
    }

    func zoom(delta: Float) {
        withCamera { $0.zoom(delta: delta) }
    }

    func resetView() {
        frameModel()
    }

    /// 在 自动 / 锁定 LOD0 / LOD1 / LOD2 之间循环
    func cycleLODLock() {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch lockedLOD {
        case .none: lockedLOD = 0
        case .some(0): lockedLOD = 1
        case .some(1): lockedLOD = 2
        default: lockedLOD = nil
        }
    }

    // MARK: 渲染模式 / 关闭模型

    func setRenderMode(_ mode: RenderMode) {
        stateLock.lock()
        renderMode = mode
        stateLock.unlock()
    }

    func cycleRenderMode() {
        stateLock.lock()
        renderMode = renderMode.next
        stateLock.unlock()
    }

    private func currentRenderMode() -> RenderMode {
        stateLock.lock()
        defer { stateLock.unlock() }
        return renderMode
    }

    /// 关闭当前模型，释放全部网格数据
    func closeModel() {
        items.removeAll()
        boundsMin = .zero
        boundsMax = .zero
        triangleCount = 0
        vertexCount = 0
        publish(FrameStats())
    }

    var hasModel: Bool { !items.isEmpty }

    private func currentLock() -> Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lockedLOD
    }

    private func statsSnapshot() -> FrameStats {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastStats
    }

    private func publish(_ stats: FrameStats) {
        stateLock.lock()
        lastStats = stats
        stateLock.unlock()
    }

    /// 依据屏幕像素半径选档，带 hysteresis 避免边界处来回跳变
    private func selectLOD(pixelRadius: Float, current: Int) -> Int {
        var lod = current
        if lod < 0 {
            // 已被剔除：半径明显变大才重新提交
            guard pixelRadius > LODThreshold.cullRadius * LODThreshold.hysteresisUp else { return -1 }
            lod = 2
        }

        while lod < 2, pixelRadius < LODThreshold.bounds[lod] * LODThreshold.hysteresisDown {
            lod += 1
        }
        while lod > 0, pixelRadius > LODThreshold.bounds[lod - 1] * LODThreshold.hysteresisUp {
            lod -= 1
        }

        if lod == 2, pixelRadius < LODThreshold.cullRadius * LODThreshold.hysteresisDown {
            return -1
        }
        return lod
    }

    private static func corners(of min: SIMD3<Float>, _ max: SIMD3<Float>) -> [SIMD3<Float>] {
        [
            SIMD3<Float>(min.x, min.y, min.z), SIMD3<Float>(max.x, min.y, min.z),
            SIMD3<Float>(min.x, max.y, min.z), SIMD3<Float>(max.x, max.y, min.z),
            SIMD3<Float>(min.x, min.y, max.z), SIMD3<Float>(max.x, min.y, max.z),
            SIMD3<Float>(min.x, max.y, max.z), SIMD3<Float>(max.x, max.y, max.z)
        ]
    }

    // MARK: 调试信息

    func debugText(fileName: String, loadSeconds: Double, lodSeconds: Double) -> String {
        let size = boundsMax - boundsMin
        let fps = Int(smoothedFPS.rounded())
        let stats = statsSnapshot()
        let lockText = currentLock().map { "锁定 LOD\($0)" } ?? "自动"
        let lodDetail = (0..<3)
            .map { "LOD\($0) \(stats.lodCounts[$0])/\(stats.lodTriangles[$0].formatted())" }
            .joined(separator: " · ")
        return """
        \(fileName) · 解析 \(String(format: "%.2f", loadSeconds)) s · LOD \(String(format: "%.2f", lodSeconds)) s
        FPS \(fps) · 网格 \(items.count.formatted()) · 三角面 \(triangleCount.formatted()) · 顶点 \(vertexCount.formatted())
        绘制 \(stats.meshCount.formatted()) 网格 / \(stats.triangleCount.formatted()) 三角面 · 剔除 \(stats.culledCount.formatted())
        \(lodDetail)
        档位 \(lockText) · L 切换 · 模式 \(currentRenderMode().title) · M 切换
        包围盒 \(String(format: "%.2f × %.2f × %.2f", size.x, size.y, size.z))
        相机距离 \(String(format: "%.2f", cameraSnapshot().distance))
        ⌘O 打开 · ⌘W 关闭 · 左键旋转 · 右键平移 · 滚轮缩放 · R 重置
        """
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        updateFPS()

        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let drawableSize = view.drawableSize
        let aspect = Float(drawableSize.width / max(drawableSize.height, 1))
        let camera = cameraSnapshot()
        let viewProjection = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix()
        let stats = encodeScene(
            encoder,
            camera: camera,
            viewProjection: viewProjection,
            drawableSize: drawableSize
        )
        publish(stats)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func encodeScene(_ encoder: MTLRenderCommandEncoder,
                             camera: OrbitCamera,
                             viewProjection: simd_float4x4,
                             drawableSize: CGSize) -> FrameStats {
        let mode = currentRenderMode()

        encoder.setRenderPipelineState(mode == .boundingBox ? linePipelineState : pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setTriangleFillMode(mode == .wireframe ? .lines : .fill)

        var uniforms = ShaderUniforms(
            model: matrix_identity_float4x4,
            viewProjection: viewProjection,
            normalMatrix: matrix_identity_float4x4,
            baseColor: SIMD4<Float>(1, 1, 1, 1),
            lightDirection: simd_normalize(SIMD3<Float>(0.45, 0.8, 0.55)),
            cameraPosition: camera.eye
        )

        // 世界单位 → 屏幕像素半径的换算系数
        let pixelsPerUnit = Float(drawableSize.height) / (2 * tan(camera.fov * 0.5))
        let locked = currentLock()
        var stats = FrameStats()

        // LOD 分色：绿 = LOD0，黄 = LOD1，红 = LOD2
        let lodColors: [SIMD4<Float>] = [
            SIMD4<Float>(0.25, 0.85, 0.4, 1),
            SIMD4<Float>(1.0, 0.8, 0.2, 1),
            SIMD4<Float>(1.0, 0.3, 0.35, 1)
        ]

        for item in items {
            let lod: Int
            if let locked {
                lod = min(locked, item.lods.count - 1)
            } else {
                let distance = max(simd_length(camera.eye - item.centerWorld), 1e-4)
                let pixelRadius = item.radiusWorld * pixelsPerUnit / distance
                lod = selectLOD(pixelRadius: pixelRadius, current: item.currentLOD)
                item.currentLOD = lod
                if lod < 0 {
                    stats.culledCount += 1
                    continue
                }
            }

            if mode == .boundingBox {
                // 用平移 + 缩放把单位立方体变成该网格的世界 AABB
                let boxMin = item.boundsMinWorld
                let boxSize = simd_max(item.boundsMaxWorld - boxMin, SIMD3<Float>(repeating: 1e-5))
                var boxModel = matrix_identity_float4x4
                boxModel.columns.0.x = boxSize.x
                boxModel.columns.1.y = boxSize.y
                boxModel.columns.2.z = boxSize.z
                boxModel.columns.3 = SIMD4<Float>(boxMin.x, boxMin.y, boxMin.z, 1)

                uniforms.model = boxModel
                uniforms.normalMatrix = matrix_identity_float4x4
                uniforms.baseColor = mode == .lodColor ? lodColors[lod] : SIMD4<Float>(0.55, 0.9, 1.0, 1)

                encoder.setCullMode(.none)
                encoder.setVertexBuffer(boxVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(boxNormalBuffer, offset: 0, index: 1)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 2)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 2)
                encoder.drawIndexedPrimitives(
                    type: .line,
                    indexCount: 24,
                    indexType: .uint32,
                    indexBuffer: boxIndexBuffer,
                    indexBufferOffset: 0
                )

                stats.meshCount += 1
                stats.lodCounts[lod] += 1
                continue
            }

            let level = item.lods[lod]
            uniforms.model = item.model
            uniforms.normalMatrix = item.normalMatrix
            uniforms.baseColor = mode == .lodColor ? lodColors[lod] : item.color

            encoder.setCullMode(item.doubleSided ? .none : .back)
            encoder.setVertexBuffer(level.positionBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(level.normalBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 2)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: level.indexCount,
                indexType: .uint32,
                indexBuffer: level.indexBuffer,
                indexBufferOffset: 0
            )

            stats.meshCount += 1
            stats.triangleCount += level.indexCount / 3
            stats.lodCounts[lod] += 1
            stats.lodTriangles[lod] += level.indexCount / 3
        }
        return stats
    }

    private func updateFPS() {
        let now = CACurrentMediaTime()
        defer { lastFrameTime = now }
        guard lastFrameTime > 0 else { return }
        let delta = now - lastFrameTime
        guard delta > 0.0001 else { return }
        let instant = 1.0 / delta
        smoothedFPS = smoothedFPS == 0 ? instant : smoothedFPS * 0.9 + instant * 0.1
    }
}
