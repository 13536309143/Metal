# MetalViewer

一个用 **Swift + Metal** 从零实现的高性能 glTF/GLB 三维模型查看器。不依赖 SceneKit / RealityKit / 任何第三方库——GLB 解析、场景图遍历、网格简化、渲染管线全部手写，可直接作为学习 Metal 与渲染引擎架构的参考实现。

实测加载 **547 万三角面 / 2149 个网格** 的工业模型：解析 0.07s、LOD 生成 0.2s，渲染 **700+ FPS**（Apple Silicon，解除垂直同步后）。

## 功能

- **GLB 查看器**：解析 glTF 2.0 二进制容器（JSON + BIN chunk）、场景图节点变换（TRS / 矩阵）、材质基色、单双面材质；缺失法线时自动面积加权平滑生成
- **三级 LOD 系统**：顶点聚类简化（同格顶点合并、退化/重复三角形剔除、薄板防塌陷），按屏幕像素半径自动选档（160px / 60px 分界），hysteresis 防抖，小于 2px 的小件直接剔除
- **四种渲染模式**：材质着色 / 三角面线框 / 包围盒线框 / LOD 分色（绿=LOD0 黄=LOD1 红=LOD2）
- **轨道相机**：旋转 / 平移 / 缩放，自动取景
- **不锁帧渲染**：`displaySyncEnabled = false` + 1ms 自旋渲染线程，窗口遮挡时自动停帧省电
- **实时调试浮层**：FPS、绘制/剔除统计、各 LOD 档位网格与三角面数、相机距离
- **交互式教学平台**：12 课教程面板（语法高亮代码 + 关键点 + 测验 + 进度追踪）、实验面板（实时调 FOV/光照/LOD 阈值）
- **完整学习文档**：循序渐进教程、逐文件源码导读、术语表、Metal 速查表（见 [`docs/`](docs/)）

## 界面预览

```
着色模式                    LOD 分色模式
┌──────────────┐          ┌──────────────┐
│  完整材质光照  │          │ 绿/黄/红分档  │
└──────────────┘          └──────────────┘
```

## 构建与运行

环境要求：**macOS 13+，Xcode 命令行工具（Swift 5.9+）**，支持 Metal 的 GPU。

```bash
git clone <repo-url>
cd Metal
swift build -c release

# 查看自带模型（需自行放置一个 .glb 到项目目录）
.build/release/MetalViewer a.glb

# 或查看任意路径的模型
.build/release/MetalViewer /path/to/model.glb
```

也可以直接 `swift run -c release MetalViewer a.glb`。

> 仓库不含示例模型（二进制文件不入库）。任意 glTF 2.0 `.glb` 文件均可，推荐用 [Khronos Sample Models](https://github.com/KhronosGroup/glTF-Sample-Models) 或自己导出的模型测试。

## 操作方式

| 操作 | 效果 |
|---|---|
| 左键拖拽 | 旋转 |
| 右键 / Shift+左键拖拽 | 平移 |
| 滚轮 | 缩放 |
| `R` | 重置视角 |
| `L` | 循环切换 LOD 锁定：自动 → 锁 LOD0 → LOD1 → LOD2 |
| `M` 或 `1`–`4` | 渲染模式：着色 / 线框 / 包围盒 / LOD 分色 |
| `⌘O` | 打开模型文件 |
| `⌘W` | 关闭当前模型 |
| `⌘Q` | 退出 |

## 学习资源

专为 Mac Metal 渲染初学者设计：

- **应用内教程**：点右上角 📘 教程，12 课从「Metal 窗口」讲到「LOD hysteresis」，每课带演示按钮和小测验
- **应用内实验**：点 🧪 实验，滑块实时调 FOV、光照方向、LOD 阈值，边改边看效果
- **文档**：[`docs/`](docs/) 含循序渐进教程、逐文件源码导读、术语表、Metal 速查表

## 架构

```
Sources/MetalViewer/
├── main.swift          入口，NSApplication 装配
├── AppDelegate.swift   窗口、菜单、加载调度（后台线程）、调试浮层、自旋渲染循环
├── ViewerView.swift    MTKView 子类，鼠标/键盘交互
├── GLBLoader.swift     GLB 容器解析 → accessor 读取 → 场景图遍历 → CPU 网格
├── LODGenerator.swift  顶点聚类式网格简化（LOD1 = 对角线/32 格子，LOD2 = /16）
└── Renderer.swift      Metal 管线（运行期编译 MSL）、LOD 选档、四种渲染模式、统计
```

关键设计：

- **LOD 选档**：`pixelRadius = 世界半径 × (视口高 / 2·tan(fov/2)) / 相机距离`；升档阈值 ×1.2、降档 ×0.8 形成 hysteresis 带，避免在边界处来回跳变
- **线程模型**：解析与 LOD 生成在后台线程；渲染在私有队列的 1ms timer 上；相机与状态用锁保护，浮层统计在主线程每 0.25s 刷新
- **内存布局**：位置 / 法线分离两块 buffer（非交错），所有层级共享 `storageModeShared`，2149 个 draw call 无实例化合批——Simple 优先

## 已知限制

- 仅支持 `.glb`（单文件二进制），暂不支持外部 `.gltf` + 分离 bin/纹理
- 仅三角形图元（mode 4），忽略纹理、蒙皮、动画、PBR 金属粗糙度（只取基色）
- LOD 用顶点聚类而非边坍缩，质量够用但不保拓扑

## License

MIT
