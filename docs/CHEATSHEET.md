# Metal 速查表

macOS Metal 渲染入门常用代码片段，可直接复制到自己的项目中。

---

## 1. 设备与队列

```swift
guard let device = MTLCreateSystemDefaultDevice() else { fatalError() }
guard let queue = device.makeCommandQueue() else { fatalError() }
```

## 2. 运行期编译着色器

```swift
let source = """
#include <metal_stdlib>
using namespace metal;
vertex float4 vertex_main(...) { ... }
fragment float4 fragment_main(...) { ... }
"""
let library = try device.makeLibrary(source: source, options: nil)
let vertex = library.makeFunction(name: "vertex_main")!
let fragment = library.makeFunction(name: "fragment_main")!
```

## 3. 创建渲染管线

```swift
let descriptor = MTLRenderPipelineDescriptor()
descriptor.vertexFunction = vertex
descriptor.fragmentFunction = fragment
descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
descriptor.depthAttachmentPixelFormat = .depth32Float
let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
```

## 4. 深度模板状态

```swift
let depth = MTLDepthStencilDescriptor()
depth.depthCompareFunction = .less
depth.isDepthWriteEnabled = true
let depthState = device.makeDepthStencilState(descriptor: depth)!
```

## 5. 上传顶点 / 索引

```swift
let positions: [Float] = [...]
let buffer = device.makeBuffer(bytes: positions,
                               length: positions.count * 4,
                               options: .storageModeShared)!
```

## 6. 每帧绘制

```swift
guard let drawable = view.currentDrawable,
      let passDescriptor = view.currentRenderPassDescriptor else { return }
passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)

guard let buffer = queue.makeCommandBuffer(),
      let encoder = buffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

encoder.setRenderPipelineState(pipeline)
encoder.setDepthStencilState(depthState)
encoder.setVertexBuffer(positionBuffer, offset: 0, index: 0)
encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
encoder.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: 0)

encoder.endEncoding()
buffer.present(drawable)
buffer.commit()
```

## 7. 线框模式

```swift
encoder.setTriangleFillMode(.lines)   // .fill 为默认填充
```

## 8. 不锁帧

```swift
(view.layer as? CAMetalLayer)?.displaySyncEnabled = false
view.isPaused = true
view.enableSetNeedsDisplay = false
// 用 timer 主动调 view.draw()
```

## 9. 相机：lookAt + perspective

```swift
func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(center - eye)
    let r = simd_normalize(simd_cross(f, up))
    let u = simd_cross(r, f)
    return simd_float4x4(columns: (
        SIMD4(r.x, u.x, -f.x, 0),
        SIMD4(r.y, u.y, -f.y, 0),
        SIMD4(r.z, u.z, -f.z, 0),
        SIMD4(-simd_dot(r, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
    ))
}

func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovY * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4(x, 0, 0, 0),
        SIMD4(0, y, 0, 0),
        SIMD4(0, 0, z, -1),
        SIMD4(0, 0, z * near, 0)
    ))
}
```

## 10. 法线矩阵

```swift
let upper = simd_float3x3(columns: (
    SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z),
    SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z),
    SIMD3(model.columns.2.x, model.columns.2.y, model.columns.2.z)
))
let normalMatrix = upper.inverse.transpose
```

## 11. Blinn-Phong 光照（MSL）

```metal
float3 n = normalize(in.normal);
float3 lightDir = normalize(u.lightDirection);
float3 viewDir = normalize(u.cameraPosition - in.worldPosition);
float3 halfVec = normalize(lightDir + viewDir);

float ndl  = max(dot(n, lightDir), 0.0);
float spec = pow(max(dot(n, halfVec), 0.0), 40.0);
float3 color = base * (0.25 + 0.75 * ndl) + spec * 0.15;
```

## 12. 平滑法线生成

```swift
var normals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
for t in stride(from: 0, to: indices.count, by: 3) {
    let (a, b, c) = (Int(indices[t]), Int(indices[t+1]), Int(indices[t+2]))
    let e1 = positions[b] - positions[a]
    let e2 = positions[c] - positions[a]
    let fn = simd_cross(e1, e2)
    normals[a] += fn; normals[b] += fn; normals[c] += fn
}
for i in normals.indices { normals[i] = simd_normalize(normals[i]) }
```

## 13. 像素半径选档

```swift
let pixelsPerUnit = viewportHeight / (2 * tan(fov * 0.5))
let pixelRadius = radiusWorld * pixelsPerUnit / max(distance, 1e-4)
let lod: Int
if pixelRadius > 160 { lod = 0 }
else if pixelRadius > 60 { lod = 1 }
else if pixelRadius > 2 { lod = 2 }
else { lod = -1 }  // 剔除
```

## 14. 常见错误

| 错误现象 | 可能原因 |
|---|---|
| 画面全黑 | clearColor 或渲染模式未设置；pipeline 未设置 |
| 模型闪烁 | 深度测试未开 / near 太小深度精度不够 |
| 法线方向错 | 没用法线矩阵（model 上 3×3 逆转置） |
| 模型变形 | 世界矩阵累积顺序错（应为 parent × local） |
| 帧率锁 60 | displaySyncEnabled 未设 false |
