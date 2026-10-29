# Metal 渲染入门教程

本项目是为 **macOS Metal 渲染初学者**准备的学习平台。本文档按「由浅入深」的顺序讲解每一个特性的原理、关键代码与观察实验，配合应用内的教程面板边看边练。

> 建议：先在应用里点右上角 **📘 教程**，跟着每课的「演示」按钮操作；遇到想深入看源码时再回到本文档。

---

## 学习路线

| 顺序 | 主题 | 对应源码 | 你将学会 |
|---|---|---|---|
| 1 | Metal 窗口与渲染循环 | `main.swift` / `AppDelegate.swift` | 用 MTKView 搭出一个能跑的 Metal 窗口 |
| 2 | 渲染管线与着色器 | `Renderer.swift` (ShaderSource) | 顶点/片元着色器如何把三角形画到屏幕 |
| 3 | GLB 模型加载 | `GLBLoader.swift` | 解析 glTF 二进制、场景图变换、accessor |
| 4 | 光照与法线 | `Renderer.swift` / `GLBLoader.swift` | Blinn-Phong、法线矩阵、平滑法线 |
| 5 | 轨道相机 | `Renderer.swift` (OrbitCamera) | 球坐标相机、view/projection 矩阵 |
| 6 | 三角面线框 | `Renderer.swift` (wireframe) | `setTriangleFillMode(.lines)` |
| 7 | 包围盒可视化 | `Renderer.swift` (boundingBox) | 用单位立方体 buffer 画任意 AABB |
| 8 | LOD 系统 | `LODGenerator.swift` | 顶点聚类简化、像素半径选档、hysteresis |

---

## 第 1 课：Metal 窗口与渲染循环

### 核心概念

Metal 本身不负责窗口，需要 `MTKView`（MetalKit 提供的 NSView 子类）承载 Metal 内容。`MTKView` 默认每帧调用它的 `delegate.draw(in:)`。

### 关键代码

```swift
// main.swift — 创建一个普通的 NSApplication
let app = NSApplication.shared
app.delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.run()

// AppDelegate.swift — 创建 MTKView
viewer = ViewerView(frame: ..., device: device)
viewer.colorPixelFormat = .bgra8Unorm_srgb
viewer.depthStencilPixelFormat = .depth32Float
```

### 不锁帧渲染循环

`MTKView` 默认和显示器垂直同步，锁定 60fps。我们想跑满 GPU，所以：

```swift
(viewer.layer as? CAMetalLayer)?.displaySyncEnabled = false  // 解除垂直同步
viewer.isPaused = true                                        // 不让系统自动 draw
viewer.enableSetNeedsDisplay = false                          // 不响应 setNeedsDisplay

let timer = DispatchSource.makeTimerSource(queue: renderQueue)
timer.schedule(deadline: .now(), repeating: .milliseconds(1))  // 1ms 检查一次
timer.setEventHandler { viewer.draw() }                         // 主动调 draw
```

⚠️ 窗口遮挡时跳过绘制，省电：

```swift
timer.setEventHandler {
    guard self.isWindowVisible else { return }
    viewer.draw()
}
```

### 实验
运行应用，看左上角 FPS。遮挡窗口，FPS 应该降到 0。

---

## 第 2 课：渲染管线与着色器

### 核心概念

Metal 渲染管线 = **顶点着色器** 处理每个顶点的位置 → 图元装配 → **片元着色器** 给每个像素上色。

本项目用 **运行期编译** `.metal` 源码（`makeLibrary(source:)`），这样 SwiftPM 无需配置 `.metal` 文件。

### 关键代码（在 `Renderer.swift` 顶部的 `ShaderSource.metal`）

```metal
// 顶点着色器：把局部坐标乘模型矩阵 → 世界坐标 → 再乘 VP 矩阵 → 裁剪空间
vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                             constant Uniforms &u [[buffer(2)]]) {
    float4 world = u.model * float4(in.position, 1.0);
    out.position = u.viewProjection * world;
    out.normal = (u.normalMatrix * float4(in.normal, 0.0)).xyz;
    out.worldPosition = world.xyz;
    return out;
}

// 片元着色器：Blinn-Phong 光照
fragment float4 fragment_main(...) {
    float3 n = normalize(in.normal);
    float ndl  = max(dot(n, lightDir), 0.0);          // 漫反射
    float spec = pow(max(dot(n, halfVec), 0.0), 40);   // 高光
    float3 color = base * (0.25 + 0.75 * ndl) + spec;
    return float4(color, 1.0);
}
```

### 上传 Uniforms

```swift
encoder.setVertexBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 2)
encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 2)
```

### 实验
在着色器里把 `base * (0.25 + 0.75 * ndl)` 改成 `base * ndl`，观察暗面变化。

---

## 第 3 课：加载 GLB 模型

### 核心概念

GLB = glTF 的二进制打包格式，结构：

```
[头部 12B] [JSON chunk] [BIN chunk]
 magic=glTF  场景/节点/网格/材质  顶点/索引原始数据
```

`accessor` 描述了「我想从 BIN 里取什么类型、多少个、偏移多少的数据」。

### 关键代码

```swift
// 1. 读头部，找 JSON 和 BIN 两个 chunk
guard header.magic == "glTF" else { throw ... }

// 2. 解析 JSON 得到节点树、网格、accessor、bufferView
let document = try JSONDecoder().decode(GLTFDocument.self, from: json)

// 3. 深度优先遍历节点树，累积世界矩阵
var stack: [(node: Int, parent: simd_float4x4)] = roots.map { ($0, .identity) }
while let (node, parent) = stack.popLast() {
    let world = parent * localMatrix(of: node)   // TRS 或 matrix
    for child in node.children ?? [] { stack.append((child, world)) }
    // 读该节点 mesh 的所有 primitive
}

// 4. 按 accessor 从 BIN 读取位置/法线/索引
let positions = try reader.floats(accessor: positionAccessor)
let indices = try reader.indices(accessor: indexAccessor, vertexCount: count)
```

### 实验
在应用里点 **打开模型** 换一个 glTF 模型试试，左上角会显示解析出来的网格/三角面数。

---

## 第 4 课：光照与法线

### 核心概念

光照需要每个顶点的 **法线方向**。glTF 模型可能没有法线，这时需要 **面积加权平滑法线**：遍历所有三角形，把每个三角形的叉积（面积）加到三个顶点上，最后归一化。

```swift
// computeSmoothNormals
let faceNormal = simd_cross(p1 - p0, p2 - p0)   // 叉积长度 = 2 × 三角形面积
for vertex in [a, b, c] { normals[vertex] += faceNormal }
// 最后归一化
```

### 法线矩阵

法线不能直接用 model 矩阵变换（因为非均匀缩放会扭曲法线），必须用 **model 矩阵上 3×3 的逆转置**：

```swift
let inverseTranspose = upper.inverse.transpose
```

### 实验
去掉平滑法线生成（直接用 (0,1,0) 作为法线），观察明暗变成一片的效果。

---

## 第 5 课：轨道相机

### 核心概念

相机用 **球坐标** 描述：`target`（目标点）、`distance`（距离）、`yaw`（水平角）、`pitch`（俯仰角）。由这四个量反推 `eye`（相机位置）：

```swift
let eye = target + distance * SIMD3(
    cos(pitch) * sin(yaw),
    sin(pitch),
    cos(pitch) * cos(yaw)
)
let view = lookAt(eye: eye, center: target, up: SIMD3(0, 1, 0))
```

### 投影矩阵

Metal 的 NDC z 范围是 `[0, 1]`（OpenGL 是 `[-1, 1]`），注意透视矩阵写法：

```swift
static func perspective(fovY, aspect, near, far) -> simd_float4x4 {
    let z = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4(x, 0, 0, 0),
        SIMD4(0, y, 0, 0),
        SIMD4(0, 0, z, -1),            // z 映射到 [0,1]
        SIMD4(0, 0, z * near, 0)
    ))
}
```

### 实验
改 `fov`（比如 90°），观察视野变化。

---

## 第 6 课：三角面线框模式

### 核心概念

线框不需要重新生成几何，只要把 Metal 的填充模式从 `.fill` 改成 `.lines`，GPU 就会把每个三角形的三条边画出来。

```swift
encoder.setTriangleFillMode(mode == .wireframe ? .lines : .fill)
encoder.drawIndexedPrimitives(type: .triangle, ...)
```

### 实验
切换到线框模式，拉近相机，观察三角面密度分布。

---

## 第 7 课：包围盒可视化

### 核心概念

AABB（轴对齐包围盒）由 `min` 和 `max` 两个三维点定义。我们预先创建一个 **单位立方体**（0..1）的顶点 buffer，对每个网格用 `平移(min) × 缩放(size)` 的矩阵变换，就能画出任意 AABB 的 12 条棱。

```swift
var boxModel = matrix_identity_float4x4
boxModel.columns.0.x = boxSize.x
boxModel.columns.1.y = boxSize.y
boxModel.columns.2.z = boxSize.z
boxModel.columns.3 = SIMD4(min.x, min.y, min.z, 1)
drawIndexedPrimitives(type: .line, indexCount: 24, ...)
```

### 实验
切换到包围盒模式，看模型由多少个小部件组成（本项目 a.glb 有 2149 个）。

---

## 第 8 课：三级 LOD 系统

### 核心概念

LOD（Level of Detail）= 根据物体在屏幕上的大小，选择不同精细度的网格。物体越小，用越简化的网格，远处看不出来但省 GPU。

**简化方法——顶点聚类**：把空间划成格子，同格的所有顶点合并成一个（位置取平均、法线归一化）。格子越大，合并越狠。

```
LOD1 cellSize = 对角线 / 32
LOD2 cellSize = 对角线 / 16
```

**选档公式**——把世界半径换算成屏幕像素半径：

```
pixelRadius = radiusWorld × (viewportHeight / (2·tan(fov/2))) / distance
```

| pixelRadius | 档位 |
|---|---|
| > 160 | LOD0（原始） |
| 60–160 | LOD1（≤50% 三角面） |
| 2–60 | LOD2（≤15%） |
| < 2 | 不画（剔除） |

**hysteresis（防抖）**：升档阈值 ×1.2，降档阈值 ×0.8。否则物体在边界附近像素半径轻微抖动，会导致档位频繁切换、画面闪烁。

### 实验
切到 **LOD 分色** 模式（绿=LOD0、黄=LOD1、红=LOD2），慢慢拉远相机，观察颜色从绿变黄再变红。

---

## 推荐延伸阅读

- [Metal Programming Guide](https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/) — Apple 官方入门
- [glTF 2.0 规范](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html) — 理解 GLB 格式
- [Real-Time Rendering](https://www.realtimerendering.com/) — 渲染圣经
