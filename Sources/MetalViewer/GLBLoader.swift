import Foundation
import simd

// MARK: - 解析结果

/// 一个可直接上传 GPU 的绘制单元：位置 / 法线 / 索引 + 材质 + 世界矩阵
struct LoadedPrimitive {
    var positions: [Float]      // 每顶点 3 个 float
    var normals: [Float]        // 每顶点 3 个 float
    var indices: [UInt32]
    var color: SIMD4<Float>
    var doubleSided: Bool
    var worldMatrix: simd_float4x4
    var localBoundsMin: SIMD3<Float>
    var localBoundsMax: SIMD3<Float>
    /// LOD0（原始）+ 各简化级别，由 LODGenerator 在后台线程填充
    var lods: [LODMesh] = []
}

struct LoadedModel {
    var primitives: [LoadedPrimitive]
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
    var triangleCount: Int
    var vertexCount: Int
    var skippedPrimitives: Int
}

enum GLBError: LocalizedError {
    case fileNotFound(String)
    case invalidContainer(String)
    case missingJSON
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "找不到文件：\(path)"
        case .invalidContainer(let reason): return "GLB 容器损坏：\(reason)"
        case .missingJSON: return "GLB 中缺少 JSON chunk"
        case .unsupported(let reason): return "暂不支持的 glTF 特性：\(reason)"
        }
    }
}

// MARK: - glTF JSON 结构（仅解析查看所需字段）

struct GLTFDocument: Decodable {
    struct Scene: Decodable {
        let nodes: [Int]?
    }

    struct Node: Decodable {
        let children: [Int]?
        let mesh: Int?
        let matrix: [Float]?
        let translation: [Float]?
        let rotation: [Float]?
        let scale: [Float]?
    }

    struct Mesh: Decodable {
        let primitives: [Primitive]
    }

    struct Primitive: Decodable {
        let attributes: [String: Int]
        let indices: Int?
        let material: Int?
        let mode: Int?
    }

    struct Accessor: Decodable {
        let bufferView: Int?
        let byteOffset: Int?
        let componentType: Int
        let normalized: Bool?
        let count: Int
        let type: String
        let min: [Float]?
        let max: [Float]?
    }

    struct BufferView: Decodable {
        let buffer: Int
        let byteOffset: Int?
        let byteLength: Int
        let byteStride: Int?
    }

    struct Buffer: Decodable {
        let uri: String?
        let byteLength: Int
    }

    struct Material: Decodable {
        struct PBR: Decodable {
            let baseColorFactor: [Float]?
        }

        let name: String?
        let doubleSided: Bool?
        let alphaMode: String?
        let pbrMetallicRoughness: PBR?
    }

    let scene: Int?
    let scenes: [Scene]?
    let nodes: [Node]?
    let meshes: [Mesh]?
    let materials: [Material]?
    let accessors: [Accessor]?
    let bufferViews: [BufferView]?
    let buffers: [Buffer]?
}

// MARK: - 加载器

enum GLBLoader {

    static func load(url: URL) throws -> LoadedModel {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GLBError.fileNotFound(url.path)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 12 else { throw GLBError.invalidContainer("文件长度不足 12 字节") }

        let header = data.withUnsafeBytes { raw -> (magic: String, version: UInt32) in
            let base = raw.baseAddress!
            let magic = String(bytes: UnsafeRawBufferPointer(start: base, count: 4), encoding: .ascii) ?? ""
            let version = base.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            return (magic, version)
        }
        guard header.magic == "glTF" else { throw GLBError.invalidContainer("魔数不是 glTF") }
        guard header.version == 2 else { throw GLBError.unsupported("glTF 版本 \(header.version)") }

        var jsonChunk: Data?
        var binChunkStart = -1
        var offset = 12

        while offset + 8 <= data.count {
            let chunk = data.withUnsafeBytes { raw -> (length: UInt32, type: UInt32) in
                let base = raw.baseAddress!
                return (base.loadUnaligned(fromByteOffset: offset, as: UInt32.self),
                        base.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
            }
            let start = offset + 8
            let end = start + Int(chunk.length)
            guard end <= data.count else { throw GLBError.invalidContainer("chunk 超出文件范围") }

            switch chunk.type {
            case 0x4E4F534A:                      // "JSON"
                jsonChunk = data.subdata(in: start..<end)
            case 0x004E4942:                      // "BIN\0"
                binChunkStart = start
            default:
                break
            }
            offset = end
        }

        guard let json = jsonChunk else { throw GLBError.missingJSON }
        let document = try JSONDecoder().decode(GLTFDocument.self, from: json)
        return try build(document: document, data: data, binStart: binChunkStart)
    }

    // MARK: 场景图遍历

    private static func build(document: GLTFDocument, data: Data, binStart: Int) throws -> LoadedModel {
        guard binStart >= 0 else { throw GLBError.invalidContainer("缺少 BIN chunk") }

        let reader = AccessorReader(document: document, data: data, binStart: binStart)
        let nodes = document.nodes ?? []
        let meshes = document.meshes ?? []
        let materials = document.materials ?? []

        var primitives: [LoadedPrimitive] = []
        var boundsMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var triangleCount = 0
        var vertexCount = 0
        var skipped = 0

        let roots: [Int]
        if let scenes = document.scenes,
           let index = document.scene ?? (scenes.isEmpty ? nil : 0),
           index >= 0, index < scenes.count,
           let sceneNodes = scenes[index].nodes {
            roots = sceneNodes
        } else {
            var childIndices = Set<Int>()
            for node in nodes { node.children?.forEach { childIndices.insert($0) } }
            roots = nodes.indices.filter { !childIndices.contains($0) }
        }

        var visited = [Bool](repeating: false, count: nodes.count)
        var stack: [(node: Int, parent: simd_float4x4)] = roots.reversed().map { ($0, matrix_identity_float4x4) }

        while let entry = stack.popLast() {
            let nodeIndex = entry.node
            guard nodeIndex >= 0, nodeIndex < nodes.count, !visited[nodeIndex] else { continue }
            visited[nodeIndex] = true

            let node = nodes[nodeIndex]
            let world = entry.parent * localMatrix(of: node)

            for child in node.children ?? [] {
                stack.append((child, world))
            }

            guard let meshIndex = node.mesh, meshIndex >= 0, meshIndex < meshes.count else { continue }

            for primitive in meshes[meshIndex].primitives {
                guard (primitive.mode ?? 4) == 4 else { skipped += 1; continue }
                guard let positionAccessor = primitive.attributes["POSITION"] else { skipped += 1; continue }

                let positions = try reader.floats(accessor: positionAccessor)
                guard positions.count >= 9, positions.count % 3 == 0 else { skipped += 1; continue }
                let count = positions.count / 3

                var normals: [Float] = []
                if let normalAccessor = primitive.attributes["NORMAL"] {
                    let raw = try reader.floats(accessor: normalAccessor)
                    if raw.count == positions.count { normals = raw }
                }

                var indices: [UInt32]
                if let indexAccessor = primitive.indices {
                    indices = try reader.indices(accessor: indexAccessor, vertexCount: count)
                } else {
                    indices = Array(0..<UInt32(count))
                }
                guard indices.count >= 3 else { skipped += 1; continue }
                if indices.count % 3 != 0 { indices.removeLast(indices.count % 3) }

                if normals.isEmpty {
                    normals = computeSmoothNormals(positions: positions, indices: indices)
                }

                var color = SIMD4<Float>(1, 1, 1, 1)
                var doubleSided = false
                if let materialIndex = primitive.material, materialIndex >= 0, materialIndex < materials.count {
                    let material = materials[materialIndex]
                    if let factor = material.pbrMetallicRoughness?.baseColorFactor, factor.count == 4 {
                        color = SIMD4<Float>(factor[0], factor[1], factor[2], factor[3])
                    }
                    doubleSided = material.doubleSided ?? false
                }

                var localMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var localMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                var i = 0
                while i < positions.count {
                    let point = SIMD3<Float>(positions[i], positions[i + 1], positions[i + 2])
                    localMin = simd_min(localMin, point)
                    localMax = simd_max(localMax, point)
                    i += 3
                }

                for corner in corners(of: localMin, localMax) {
                    let worldPoint = world * SIMD4<Float>(corner, 1)
                    let point = SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
                    boundsMin = simd_min(boundsMin, point)
                    boundsMax = simd_max(boundsMax, point)
                }

                primitives.append(LoadedPrimitive(
                    positions: positions,
                    normals: normals,
                    indices: indices,
                    color: color,
                    doubleSided: doubleSided,
                    worldMatrix: world,
                    localBoundsMin: localMin,
                    localBoundsMax: localMax
                ))
                triangleCount += indices.count / 3
                vertexCount += count
            }
        }

        if primitives.isEmpty {
            boundsMin = .zero
            boundsMax = .zero
        }

        return LoadedModel(
            primitives: primitives,
            boundsMin: boundsMin,
            boundsMax: boundsMax,
            triangleCount: triangleCount,
            vertexCount: vertexCount,
            skippedPrimitives: skipped
        )
    }

    // MARK: 变换

    private static func localMatrix(of node: GLTFDocument.Node) -> simd_float4x4 {
        // 规范规定：存在 matrix 时忽略 TRS
        if let m = node.matrix, m.count == 16 {
            return simd_float4x4(columns: (
                SIMD4<Float>(m[0], m[1], m[2], m[3]),
                SIMD4<Float>(m[4], m[5], m[6], m[7]),
                SIMD4<Float>(m[8], m[9], m[10], m[11]),
                SIMD4<Float>(m[12], m[13], m[14], m[15])
            ))
        }

        var translation = matrix_identity_float4x4
        if let t = node.translation, t.count == 3 {
            translation.columns.3 = SIMD4<Float>(t[0], t[1], t[2], 1)
        }

        var rotation = matrix_identity_float4x4
        if let q = node.rotation, q.count == 4 {
            rotation = simd_float4x4(simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3]))
        }

        var scale = matrix_identity_float4x4
        if let s = node.scale, s.count == 3, s[0] != 0, s[1] != 0, s[2] != 0 {
            scale.columns.0.x = s[0]
            scale.columns.1.y = s[1]
            scale.columns.2.z = s[2]
        }

        return translation * rotation * scale
    }

    private static func corners(of min: SIMD3<Float>, _ max: SIMD3<Float>) -> [SIMD3<Float>] {
        [
            SIMD3<Float>(min.x, min.y, min.z), SIMD3<Float>(max.x, min.y, min.z),
            SIMD3<Float>(min.x, max.y, min.z), SIMD3<Float>(max.x, max.y, min.z),
            SIMD3<Float>(min.x, min.y, max.z), SIMD3<Float>(max.x, min.y, max.z),
            SIMD3<Float>(min.x, max.y, max.z), SIMD3<Float>(max.x, max.y, max.z)
        ]
    }

    // MARK: 缺失法线时的平滑法线生成

    private static func computeSmoothNormals(positions: [Float], indices: [UInt32]) -> [Float] {
        var normals = [Float](repeating: 0, count: positions.count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]) * 3
            let b = Int(indices[i + 1]) * 3
            let c = Int(indices[i + 2]) * 3
            guard a + 2 < positions.count, b + 2 < positions.count, c + 2 < positions.count else {
                i += 3
                continue
            }
            let p0 = SIMD3<Float>(positions[a], positions[a + 1], positions[a + 2])
            let p1 = SIMD3<Float>(positions[b], positions[b + 1], positions[b + 2])
            let p2 = SIMD3<Float>(positions[c], positions[c + 1], positions[c + 2])
            let faceNormal = simd_cross(p1 - p0, p2 - p0)          // 面积加权
            for base in [a, b, c] {
                normals[base] += faceNormal.x
                normals[base + 1] += faceNormal.y
                normals[base + 2] += faceNormal.z
            }
            i += 3
        }

        var v = 0
        while v < normals.count {
            var normal = SIMD3<Float>(normals[v], normals[v + 1], normals[v + 2])
            let length = simd_length(normal)
            normal = length > 1e-8 ? normal / length : SIMD3<Float>(0, 1, 0)
            normals[v] = normal.x
            normals[v + 1] = normal.y
            normals[v + 2] = normal.z
            v += 3
        }
        return normals
    }
}

// MARK: - accessor 读取

private struct AccessorReader {
    let document: GLTFDocument
    let data: Data
    let binStart: Int

    func floats(accessor index: Int) throws -> [Float] {
        guard let accessors = document.accessors, index >= 0, index < accessors.count else {
            throw GLBError.invalidContainer("accessor \(index) 不存在")
        }
        let accessor = accessors[index]
        let components = componentCount(of: accessor.type)
        guard accessor.count > 0 else { return [] }

        guard let viewIndex = accessor.bufferView,
              let views = document.bufferViews,
              viewIndex >= 0, viewIndex < views.count else {
            // 仅有 sparse 数据的 accessor：暂不支持，退化为 0
            return [Float](repeating: 0, count: accessor.count * components)
        }

        let view = views[viewIndex]
        guard view.buffer == 0 else { throw GLBError.unsupported("多个 buffer 的 glTF") }

        let componentSize = byteSize(of: accessor.componentType)
        let stride = view.byteStride ?? components * componentSize
        let base = binStart + (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        let needed = (accessor.count - 1) * stride + components * componentSize
        guard base >= 0, base + needed <= data.count else {
            throw GLBError.invalidContainer("accessor \(index) 数据越界")
        }

        var result = [Float](repeating: 0, count: accessor.count * components)
        let componentType = accessor.componentType
        let normalized = accessor.normalized ?? false

        data.withUnsafeBytes { raw in
            let basePointer = raw.baseAddress!
            if componentType == 5126 && stride == components * 4 {
                // 连续 float：整块拷贝
                result.withUnsafeMutableBytes { destination in
                    destination.copyMemory(from: UnsafeRawBufferPointer(
                        start: basePointer.advanced(by: base),
                        count: accessor.count * components * 4
                    ))
                }
            } else {
                result.withUnsafeMutableBufferPointer { destination in
                    for element in 0..<accessor.count {
                        let elementPointer = basePointer.advanced(by: base + element * stride)
                        for component in 0..<components {
                            destination[element * components + component] = readValue(
                                elementPointer.advanced(by: component * componentSize),
                                componentType: componentType,
                                normalized: normalized
                            )
                        }
                    }
                }
            }
        }
        return result
    }

    func indices(accessor index: Int, vertexCount: Int) throws -> [UInt32] {
        guard let accessors = document.accessors, index >= 0, index < accessors.count else {
            throw GLBError.invalidContainer("accessor \(index) 不存在")
        }
        let accessor = accessors[index]
        guard accessor.count > 0 else { return [] }
        guard [5121, 5123, 5125].contains(accessor.componentType) else {
            throw GLBError.unsupported("索引组件类型 \(accessor.componentType)")
        }

        guard let viewIndex = accessor.bufferView,
              let views = document.bufferViews,
              viewIndex >= 0, viewIndex < views.count else {
            return Array(0..<UInt32(vertexCount))
        }

        let view = views[viewIndex]
        guard view.buffer == 0 else { throw GLBError.unsupported("多个 buffer 的 glTF") }

        let componentSize = byteSize(of: accessor.componentType)
        let stride = view.byteStride ?? componentSize
        let base = binStart + (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        let needed = (accessor.count - 1) * stride + componentSize
        guard base >= 0, base + needed <= data.count else {
            throw GLBError.invalidContainer("索引 accessor \(index) 数据越界")
        }

        var result = [UInt32](repeating: 0, count: accessor.count)
        let componentType = accessor.componentType
        let lastVertex = UInt32(max(vertexCount - 1, 0))

        data.withUnsafeBytes { raw in
            let basePointer = raw.baseAddress!
            result.withUnsafeMutableBufferPointer { destination in
                for element in 0..<accessor.count {
                    let pointer = basePointer.advanced(by: base + element * stride)
                    let value: UInt32
                    switch componentType {
                    case 5121: value = UInt32(pointer.loadUnaligned(fromByteOffset: 0, as: UInt8.self))
                    case 5123: value = UInt32(pointer.loadUnaligned(fromByteOffset: 0, as: UInt16.self))
                    default:   value = pointer.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                    }
                    destination[element] = min(value, lastVertex)
                }
            }
        }
        return result
    }

    private func componentCount(of type: String) -> Int {
        switch type {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4": return 4
        case "MAT2": return 4
        case "MAT3": return 9
        case "MAT4": return 16
        default: return 1
        }
    }

    private func byteSize(of componentType: Int) -> Int {
        switch componentType {
        case 5120, 5121: return 1
        case 5122, 5123: return 2
        case 5125, 5126: return 4
        default: return 4
        }
    }

    private func readValue(_ pointer: UnsafeRawPointer, componentType: Int, normalized: Bool) -> Float {
        switch componentType {
        case 5120:
            let value = pointer.loadUnaligned(fromByteOffset: 0, as: Int8.self)
            return normalized ? max(Float(value) / 127, -1) : Float(value)
        case 5121:
            let value = pointer.loadUnaligned(fromByteOffset: 0, as: UInt8.self)
            return normalized ? Float(value) / 255 : Float(value)
        case 5122:
            let value = pointer.loadUnaligned(fromByteOffset: 0, as: Int16.self)
            return normalized ? max(Float(value) / 32767, -1) : Float(value)
        case 5123:
            let value = pointer.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
            return normalized ? Float(value) / 65535 : Float(value)
        case 5125:
            return Float(pointer.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        case 5126:
            return pointer.loadUnaligned(fromByteOffset: 0, as: Float.self)
        default:
            return 0
        }
    }
}
