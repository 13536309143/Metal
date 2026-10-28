import Foundation
import simd

// MARK: - 单一细节层级

/// 一个 LOD 层级的 CPU 网格数据（布局与 LOD0 一致，可直接上传 GPU）
struct LODMesh {
    var positions: [Float]
    var normals: [Float]
    var indices: [UInt32]
}

// MARK: - 顶点聚类式 LOD 生成

/// LOD0 为原始网格；LOD1 / LOD2 通过把顶点按空间格子聚类、再把同格顶点合并的方式生成。
/// 处理在后台线程完成，不影响渲染。
enum LODGenerator {

    /// LOD1 的格子尺寸 = 模型对角线 / 32，LOD2 更粗（/16）
    private static let lod1Divisor: Float = 32
    private static let lod2Divisor: Float = 16
    /// 三角面太少的部件不生成 LOD（简化收益低于开销）
    private static let minimumTriangles = 256

    static func generate(model: inout LoadedModel) {
        guard !model.primitives.isEmpty else { return }
        let sceneDiagonal = max(simd_length(model.boundsMax - model.boundsMin), 1e-6)

        for index in model.primitives.indices {
            model.primitives[index].lods = levels(for: model.primitives[index], sceneDiagonal: sceneDiagonal)
        }
    }

    // MARK: 各级构造

    private static func levels(for primitive: LoadedPrimitive, sceneDiagonal: Float) -> [LODMesh] {
        let original = LODMesh(
            positions: primitive.positions,
            normals: primitive.normals,
            indices: primitive.indices
        )

        guard original.indices.count / 3 >= minimumTriangles,
              original.normals.count == original.positions.count else {
            return [original]
        }

        // 部件在世界中太小则始终用原始网格，省掉无意义的简化计算
        let localSize = primitive.localBoundsMax - primitive.localBoundsMin
        let matrix = primitive.worldMatrix
        let worldScale = SIMD3<Float>(
            simd_length(SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)),
            simd_length(SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)),
            simd_length(SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
        )
        let worldDiagonal = simd_length(localSize * worldScale)
        guard worldDiagonal > sceneDiagonal / 500 else { return [original] }

        let localDiagonal = max(simd_length(localSize), 1e-6)
        let shortestEdge = max(min(localSize.x, min(localSize.y, localSize.z)), localDiagonal * 0.0001)
        // 薄板（最短边很短）不外扩到超过最短边的 40%，避免整块塌成一片
        let shrinkLimit = shortestEdge * 0.4
        let floorCell = localDiagonal * 0.001

        let cell1 = max(min(localDiagonal / lod1Divisor, shrinkLimit), floorCell)
        let cell2 = max(min(localDiagonal / lod2Divisor, shrinkLimit), floorCell)

        guard let lod1 = cluster(original, cellSize: cell1) else { return [original] }

        var result: [LODMesh] = [original, lod1]
        let originalTriangles = original.indices.count / 3

        if let lod2 = cluster(original, cellSize: cell2),
           lod2.indices.count < lod1.indices.count,
           lod2.indices.count / 3 >= 100,
           lod2.indices.count * 100 >= originalTriangles * 3 {
            result.append(lod2)
        } else {
            // 过于简陋（<3% 或 <100 面）时复用 LOD1
            result.append(lod1)
        }
        return result
    }

    // MARK: 顶点聚类

    private struct CellKey: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    /// 把同格子的顶点合并为一个顶点（位置取平均、法线归一化），再重建三角形
    private static func cluster(_ mesh: LODMesh, cellSize: Float) -> LODMesh? {
        let vertexCount = mesh.positions.count / 3
        guard vertexCount > 0, cellSize > 0, mesh.normals.count == mesh.positions.count else { return nil }

        let inverse = 1 / cellSize
        var lookup = [CellKey: Int32](minimumCapacity: vertexCount / 2)
        var remap = [Int32](repeating: 0, count: vertexCount)
        var firstVertex: [Int32] = []
        var clusterCount: [Float] = []
        var positionSums: [Float] = []
        var normalSums: [Float] = []

        for vertex in 0..<vertexCount {
            let offset = vertex * 3
            let x = mesh.positions[offset]
            let y = mesh.positions[offset + 1]
            let z = mesh.positions[offset + 2]

            let key = CellKey(
                x: Int32((x * inverse).rounded(.down)),
                y: Int32((y * inverse).rounded(.down)),
                z: Int32((z * inverse).rounded(.down))
            )

            let cluster: Int32
            if let existing = lookup[key] {
                cluster = existing
            } else {
                cluster = Int32(firstVertex.count)
                lookup[key] = cluster
                firstVertex.append(Int32(vertex))
                clusterCount.append(0)
                positionSums.append(contentsOf: [0, 0, 0])
                normalSums.append(contentsOf: [0, 0, 0])
            }

            remap[vertex] = cluster
            let base = Int(cluster) * 3
            clusterCount[Int(cluster)] += 1
            positionSums[base] += x
            positionSums[base + 1] += y
            positionSums[base + 2] += z
            normalSums[base] += mesh.normals[offset]
            normalSums[base + 1] += mesh.normals[offset + 1]
            normalSums[base + 2] += mesh.normals[offset + 2]
        }

        let count = firstVertex.count
        guard count > 0 else { return nil }

        var positions = [Float](repeating: 0, count: count * 3)
        var normals = [Float](repeating: 0, count: count * 3)

        for cluster in 0..<count {
            let base = cluster * 3
            let inverseCount = 1 / clusterCount[cluster]
            positions[base] = positionSums[base] * inverseCount
            positions[base + 1] = positionSums[base + 1] * inverseCount
            positions[base + 2] = positionSums[base + 2] * inverseCount

            var normal = SIMD3<Float>(normalSums[base], normalSums[base + 1], normalSums[base + 2])
            if simd_length_squared(normal) < 1e-10 {
                // 双面薄板两侧法线相消时，退回该格子首个顶点的法线
                let first = Int(firstVertex[cluster]) * 3
                normal = SIMD3<Float>(mesh.normals[first], mesh.normals[first + 1], mesh.normals[first + 2])
            }
            if simd_length_squared(normal) < 1e-10 {
                normal = SIMD3<Float>(0, 1, 0)
            } else {
                normal = simd_normalize(normal)
            }
            normals[base] = normal.x
            normals[base + 1] = normal.y
            normals[base + 2] = normal.z
        }

        // 重建索引：丢弃退化三角形与重复三角形
        var indices: [UInt32] = []
        indices.reserveCapacity(mesh.indices.count)
        var seen = Set<UInt64>()
        let canDeduplicate = count < (1 << 21)
        if canDeduplicate {
            seen.reserveCapacity(mesh.indices.count / 3)
        }
        let areaEpsilon = cellSize * cellSize * 0.001

        var cursor = 0
        while cursor + 2 < mesh.indices.count {
            let sourceA = Int(mesh.indices[cursor])
            let sourceB = Int(mesh.indices[cursor + 1])
            let sourceC = Int(mesh.indices[cursor + 2])
            cursor += 3
            guard sourceA < vertexCount, sourceB < vertexCount, sourceC < vertexCount else { continue }

            var a = UInt32(remap[sourceA])
            var b = UInt32(remap[sourceB])
            var c = UInt32(remap[sourceC])
            if a == b || b == c || a == c { continue }

            let ax = positions[Int(a) * 3], ay = positions[Int(a) * 3 + 1], az = positions[Int(a) * 3 + 2]
            let bx = positions[Int(b) * 3], by = positions[Int(b) * 3 + 1], bz = positions[Int(b) * 3 + 2]
            let cx = positions[Int(c) * 3], cy = positions[Int(c) * 3 + 1], cz = positions[Int(c) * 3 + 2]
            let edge1 = SIMD3<Float>(bx - ax, by - ay, bz - az)
            let edge2 = SIMD3<Float>(cx - ax, cy - ay, cz - az)
            if simd_length(simd_cross(edge1, edge2)) < areaEpsilon { continue }

            if canDeduplicate {
                if a > b { swap(&a, &b) }
                if b > c { swap(&b, &c) }
                if a > b { swap(&a, &b) }
                let key = UInt64(a) | (UInt64(b) << 21) | (UInt64(c) << 42)
                if !seen.insert(key).inserted { continue }
            }

            indices.append(a)
            indices.append(b)
            indices.append(c)
        }

        guard indices.count >= 3 else { return nil }
        return LODMesh(positions: positions, normals: normals, indices: indices)
    }
}
