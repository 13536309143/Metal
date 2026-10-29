# 术语表

按字母顺序，解释本项目涉及的 Metal / 渲染 / glTF 术语。

## A
- **AABB (Axis-Aligned Bounding Box)**：轴对齐包围盒，用 min/max 两个三维点定义的长方体，边与坐标轴平行。计算极快，用于剔除与碰撞。
- **Accessor**：glTF 中的数据描述符，定义「从 BIN 里取什么类型、多少个、偏移多少的数据」。

## B
- **Blinn-Phong**：一种局部光照模型，漫反射用 N·L，高光用 (N·H)^shininess，其中 H 是光线方向与视线方向的半角向量。

## C
- **CAMetalLayer**：Core Animation 的 Metal 层，MTKView 底层就是它。`displaySyncEnabled=false` 可解除垂直同步。
- **cellSize**：顶点聚类中空间格子的边长。越大，合并越狠，LOD 越粗糙。

## D
- **DrawItem**：本项目中一个可绘制的网格单元，持有三级 LOD buffer、世界包围球、材质等。
- **draw call**：一次 `drawIndexedPrimitives` 调用。本项目 2149 个部件 = 2149 次 draw call。

## F
- **FOV (Field of View)**：视野角，越大看到的范围越广，物体显得越小。
- **Fragment Shader (片元着色器)**：对光栅化后每个像素执行的着色器，决定最终颜色。

## G
- **GLB**：glTF 的二进制单文件打包格式（.glb），由 头部 + JSON chunk + BIN chunk 组成。

## H
- **Hysteresis (滞后)**：升档和降档用不同阈值，防止状态在边界来回跳变。本项目升档 ×1.2、降档 ×0.8。

## L
- **LOD (Level of Detail)**：细节层次。根据物体在屏幕上的大小，选择不同精细度的网格，远处用粗网格省 GPU。

## M
- **Metal**：Apple 的底层图形与计算 API，相当于 OpenGL/Vulkan 的 Apple 版。
- **MSL (Metal Shading Language)**：Metal 的着色器语言，基于 C++。
- **MTKView**：MetalKit 提供的 NSView 子类，自动管理 CAMetalLayer 和 drawable。
- **MTLBuffer**：Metal 的内存缓冲，可在 CPU 和 GPU 间共享。

## N
- **NDC (Normalized Device Coordinates)**：归一化设备坐标。Metal 的 NDC z 范围是 [0,1]，OpenGL 是 [-1,1]。
- **Normal Matrix (法线矩阵)**：model 矩阵上 3×3 部分的逆转置，用于正确变换法线（避免非均匀缩放扭曲）。

## P
- **Pipeline State (渲染管线状态)**：预编译的着色器 + 顶点布局 + 像素格式的组合，绘制时设置一次。
- **Primitive (图元)**：glTF 中一个 mesh 的一个子网格，含 attribute（POSITION/NORMAL 等）和 indices。

## R
- **RenderPass**：一次渲染过程，定义颜色/深度附件的清除与加载操作。
- **Rotation (TRS)**：节点变换的旋转分量，通常用四元数表示。

## S
- **SIMD**：Apple 的向量/矩阵类型（SIMD3/Float, simd_float4x4 等），可被 GPU 直接使用。
- **Stage-in**：MSL 中顶点输入的属性标记，由 MTLVertexDescriptor 描述布局。

## T
- **TRS**：Translation（平移）+ Rotation（旋转）+ Scale（缩放），glTF 节点的标准变换表示。

## U
- **Uniforms**：每次绘制不变的常量数据（模型矩阵、VP 矩阵、光照参数等），通过 buffer 传给着色器。

## V
- **Vertex Shader (顶点着色器)**：对每个顶点执行，输出裁剪空间坐标和需插值的属性。
- **View Matrix**：把世界坐标变换到相机空间的矩阵，由 eye/target/up 生成（lookAt）。
- **View-Projection (VP) Matrix**：view × projection，把世界坐标直接变换到裁剪空间。

## W
- **World Matrix (模型矩阵)**：把局部坐标变换到世界坐标的矩阵，由节点的 TRS 沿场景图累积得到。
