# 源码导读（逐文件）

按依赖顺序阅读，每节说明「这个文件解决什么问题」「核心数据结构」「关键函数」「建议阅读顺序」。

---

## 1. `main.swift` — 程序入口

最薄的一层，只做三件事：创建 `NSApplication`、设置 `AppDelegate`、启动 run loop。

```
let app = NSApplication.shared
app.delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.run()
```

> 阅读建议：1 分钟。知道入口在哪即可。

---

## 2. `AppDelegate.swift` — 窗口 / 调度 / UI

**职责**：装配窗口、MTKView、控制面板、教程面板、实验面板；管理模型加载（后台线程）、渲染循环（私有队列 timer）、统计刷新（主线程 timer）。

**核心结构**：
- `OverlayPanel` — 左上角统计浮层（不拦截鼠标，hitTest 返回 nil）
- `ControlPanel` — 右上角按钮面板（打开/关闭、渲染模式、LOD 锁定、教程/实验开关）
- `AppDelegate` — 主控制器

**关键流程**：
```
applicationDidFinishLaunching
  └─ 创建窗口/MTKView（displaySyncEnabled=false）
  └─ 安装菜单
  └─ loadModel() → 后台线程 GLBLoader.load + LODGenerator
       └─ 主线程 install() → Renderer.setModel / frameModel
            └─ startRenderLoop() → 1ms timer 调 viewer.draw()
            └─ startStatsTimer() → 0.25s 刷新 overlay
```

**线程模型（重要）**：
- 渲染线程：`renderQueue`（userInteractive），1ms timer，调 `viewer.draw()`
- 加载线程：global(userInitiated)，解析 GLB + 生成 LOD
- 主线程：UI、菜单、浮层刷新
- 相机/状态：`cameraLock` / `stateLock` 保护跨线程读写

> 阅读建议：重点看 `startRenderLoop` 和 `install`。

---

## 3. `ViewerView.swift` — 输入交互

**职责**：MTKView 子类，把鼠标/键盘事件翻译成相机操作。

**核心映射**：

| 输入 | 操作 |
|---|---|
| 左键拖拽 | `camera.orbit(dx, dy)` |
| 右键 / Shift+左键 | `camera.pan(dx, dy)` |
| 滚轮 | `camera.zoom(delta)` |
| 键盘 R/1-4/M/L | 重置视角 / 切换渲染模式 / LOD 锁定 |

> 所有相机修改走 `renderer.withCamera { ... }`，在锁内修改，渲染线程同一时刻只能读。

---

## 4. `GLBLoader.swift` — glTF 解析

**职责**：把 `.glb` 文件变成 CPU 侧的 `[LoadedPrimitive]`（位置/法线/索引 + 材质 + 世界矩阵）。

**解析流程**：
```
1. 读 12 字节头 → 校验 magic="glTF", version=2
2. 遍历 chunk → 取 JSON chunk 和 BIN chunk
3. JSONDecoder 解码 GLTFDocument
4. 深度优先遍历节点树，累积 world 矩阵
5. 对每个 mesh primitive：
   - 按 accessor 从 BIN 读 POSITION / NORMAL / indices
   - 缺法线 → computeSmoothNormals()
   - 读材质基色 / doubleSided
   - 计算局部 AABB，累积全局 AABB
```

**关键类型**：
- `LoadedPrimitive` — 一个绘制单元
- `AccessorReader` — 封装「从 BIN 按 accessor 取数」的偏移/步长/类型处理

**容易踩坑**：
- accessor 可能无 bufferView（sparse），本项目不支持
- indices 组件类型可能是 UNSIGNED_BYTE/SHORT/INT，需统一转 UInt32
- mode != 4（非三角形）直接跳过

> 阅读建议：先看 `load` 主流程，再看 `build` 的节点遍历，最后看 `AccessorReader`。

---

## 5. `LODGenerator.swift` — 网格简化

**职责**：给每个 `LoadedPrimitive` 生成 3 档简化网格（原始 / ≤50% / ≤15% 三角面）。

**算法——顶点聚类**：
```
1. 计算模型对角线
2. cellSize = diagonal / 32（LOD1）或 /16（LOD2）
   且 cellSize ≤ 最短边 × 0.4（防薄板塌陷）
3. 对每个顶点计算所在格子坐标 (floor(pos / cellSize))
4. 同格顶点合并：位置取平均，法线累加后归一化
5. 重建索引：每三角形查新顶点表，丢弃退化/零面积/重复
6. LOD2 若 <3% 或 <100 面 → 复用 LOD1
```

**输出**：`[LODMesh]`，每项含 position/normal/index 数组。

> 阅读建议：核心在 `simplify(primitive:cellSize:)`。

---

## 6. `Renderer.swift` — Metal 渲染核心

最大的文件，分模块：

### 6.1 `ShaderSource.metal`
运行期编译的 MSL 源码。包含 Uniforms 结构体、`vertex_main`、`fragment_main`（Blinn-Phong）。

### 6.2 `ShaderUniforms` / `Matrix`
- `ShaderUniforms` — CPU/ GPU 共享的 uniform 布局（必须和 MSL 完全一致）
- `Matrix` — lookAt / perspective / normalMatrix 工具函数

### 6.3 `OrbitCamera`
球坐标相机：target + distance + yaw + pitch → eye → view/projection 矩阵。

### 6.4 `Renderer` 主类
- `init` — 创建设备/队列/管线/深度状态，运行期编译着色器
- `setModel` — 把 LODMesh 上传到 MTLBuffer，构建 `[DrawItem]`
- `draw(in:)` — 每帧：取相机快照 → 清屏 → encodeScene → 提交
- `encodeScene` — 设置管线/填充模式，遍历 DrawItem 选 LOD 并绘制
- `selectLOD` — 按像素半径 + hysteresis 选档
- 渲染模式：shaded / wireframe / boundingBox / lodColor
- 实验参数：`setFOVDegrees` / `setLightDirection` / `setLODThresholds`

**DrawItem**：
```swift
struct DrawItem {
    var lods: [LODLevel]        // 三级 buffer
    var centerWorld, radiusWorld // 世界包围球（选档用）
    var currentLOD: Int          // 跨帧 hysteresis 状态
    var color, model, normalMatrix, doubleSided
}
```

> 阅读建议：按 init → setModel → draw → encodeScene → selectLOD 顺序读。

---

## 7. `TutorialPanel.swift` / `ExperimentPanel.swift` — 教学 UI

- `TutorialPanel` — 左侧课程目录（带难度、完成进度）、右侧富文本（语法高亮代码、关键点、测验）
- `ExperimentPanel` — 滑块实时调 FOV / 光照方向 / LOD 阈值，直接反馈到渲染

`CodeHighlighter` 用正则做简易语法高亮（关键字、字符串、数字、类型、函数名）。

---

## 阅读路线图（推荐）

1. `main.swift` → `AppDelegate.swift`（了解整体装配）
2. `ViewerView.swift`（知道输入怎么来）
3. `Renderer.swift` 的 `ShaderSource` + `Matrix` + `OrbitCamera`（数学基础）
4. `Renderer.swift` 的 `Renderer.init` + `setModel` + `draw`（渲染主流程）
5. `GLBLoader.swift`（数据从哪来）
6. `LODGenerator.swift`（优化进阶）
7. `TutorialPanel` / `ExperimentPanel`（教学功能）
