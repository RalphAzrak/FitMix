import CoreGraphics
import Foundation
import simd

// The avatar's body is described as one smooth signed-distance field: limbs, torso, hands, shoes and head are
// blended together with smooth unions, so the surface has no seams or overlapping parts. The field is then
// turned into a single closed triangle mesh with surface nets.

nonisolated enum BodyMath {
    @inline(__always) static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Polynomial smooth minimum: blends two surfaces over a band of width `k`.
    @inline(__always) static func smin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        guard k > 0 else { return min(a, b) }
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k * 0.25
    }

    @inline(__always) static func smax(_ a: Float, _ b: Float, _ k: Float) -> Float { -smin(-a, -b, k) }

    @inline(__always) static func ellipsoid(_ q: SIMD3<Float>, _ r: SIMD3<Float>) -> Float {
        let k1 = simd_length(q / (r * r))
        guard k1 > 1e-9 else { return -r.min() }
        let k0 = simd_length(q / r)
        return k0 * (k0 - 1) / k1
    }

    /// Exact distance to a capsule whose radius changes from `r1` at `a` to `r2` at `b`.
    @inline(__always) static func roundCone(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r1: Float, _ r2: Float) -> Float {
        let ba = b - a
        let l2 = simd_dot(ba, ba)
        let rr = r1 - r2
        let a2 = l2 - rr * rr
        let il2 = 1 / l2
        let pa = p - a
        let y = simd_dot(pa, ba)
        let z = y - l2
        let xv = pa * l2 - ba * y
        let x2 = simd_dot(xv, xv)
        let y2 = y * y * l2
        let z2 = z * z * l2
        let k = sign(rr) * rr * rr * x2
        if sign(z) * a2 * z2 > k { return (x2 + z2).squareRoot() * il2 - r2 }
        if sign(y) * a2 * y2 < k { return (x2 + y2).squareRoot() * il2 - r1 }
        return ((x2 * a2 * il2).squareRoot() + y * rr) * il2 - r1
    }

    @inline(__always) static func sign(_ x: Float) -> Float { x > 0 ? 1 : (x < 0 ? -1 : 0) }

    static func distanceToSegment(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let ba = b - a
        let t = min(max(simd_dot(p - a, ba) / max(simd_dot(ba, ba), 1e-9), 0), 1)
        return simd_length(p - (a + ba * t))
    }
}

/// One building block of the body field, combined with everything before it.
nonisolated struct SDFShape: Sendable {
    enum Kind: Sendable {
        case ellipsoid(centre: SIMD3<Float>, radii: SIMD3<Float>, toLocal: simd_float3x3)
        case roundCone(a: SIMD3<Float>, b: SIMD3<Float>, ra: Float, rb: Float)
        /// An ellipsoid kept only on one side of a plane (used for the hair).
        case cappedEllipsoid(centre: SIMD3<Float>, radii: SIMD3<Float>, planePoint: SIMD3<Float>, planeNormal: SIMD3<Float>, capK: Float)
    }

    enum Op: Sendable { case union, subtract }

    let kind: Kind
    let op: Op
    let k: Float
    let boundCentre: SIMD3<Float>
    let boundRadius: Float

    static func ellipsoid(_ c: SIMD3<Float>, _ r: SIMD3<Float>, axes: simd_float3x3 = matrix_identity_float3x3,
                          k: Float, op: Op = .union) -> SDFShape {
        SDFShape(kind: .ellipsoid(centre: c, radii: r, toLocal: axes.transpose), op: op, k: k,
                 boundCentre: c, boundRadius: r.max())
    }

    static func cone(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ ra: Float, _ rb: Float, k: Float) -> SDFShape {
        SDFShape(kind: .roundCone(a: a, b: b, ra: ra, rb: rb), op: .union, k: k,
                 boundCentre: (a + b) * 0.5, boundRadius: simd_length(b - a) * 0.5 + max(ra, rb))
    }

    static func cappedEllipsoid(_ c: SIMD3<Float>, _ r: SIMD3<Float>, planePoint: SIMD3<Float>, planeNormal: SIMD3<Float>,
                                capK: Float, k: Float) -> SDFShape {
        SDFShape(kind: .cappedEllipsoid(centre: c, radii: r, planePoint: planePoint, planeNormal: simd_normalize(planeNormal), capK: capK),
                 op: .union, k: k, boundCentre: c, boundRadius: r.max())
    }

    @inline(__always) func distance(_ p: SIMD3<Float>) -> Float {
        switch kind {
        case .ellipsoid(let c, let r, let toLocal):
            return BodyMath.ellipsoid(toLocal * (p - c), r)
        case .roundCone(let a, let b, let ra, let rb):
            return BodyMath.roundCone(p, a, b, ra, rb)
        case .cappedEllipsoid(let c, let r, let pp, let n, let capK):
            return BodyMath.smax(BodyMath.ellipsoid(p - c, r), -simd_dot(p - pp, n), capK)
        }
    }
}

/// A limb: its parts blend with one another freely, but join the body only near `joint`, so an arm hanging
/// close to the torso stays separate from it instead of webbing to it.
nonisolated struct SDFGroup: Sendable {
    let shapes: [SDFShape]
    let joint: SIMD3<Float>
    let blendK: Float
    let blendRadius: Float
    let boundCentre: SIMD3<Float>
    let boundRadius: Float

    init(_ shapes: [SDFShape], joint: SIMD3<Float>, blendK: Float, blendRadius: Float) {
        self.shapes = shapes
        self.joint = joint
        self.blendK = blendK
        self.blendRadius = blendRadius
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for s in shapes { lo = simd_min(lo, s.boundCentre - s.boundRadius); hi = simd_max(hi, s.boundCentre + s.boundRadius) }
        boundCentre = (lo + hi) * 0.5
        boundRadius = simd_length(hi - lo) * 0.5
    }

    @inline(__always) func blend(at p: SIMD3<Float>) -> Float {
        blendK * (1 - BodyMath.smoothstep(blendRadius * 0.5, blendRadius, simd_length(p - joint)))
    }
}

/// The whole body. Evaluation runs in C (see Mesher/AvatarMesher.c), so it stays fast in Debug builds.
nonisolated struct BodyField: @unchecked Sendable {
    /// Owns the C copies of the shapes, which the C field points into.
    private final class Storage {
        let shapes: [UnsafeMutableBufferPointer<FMShape>]
        let groups: UnsafeMutableBufferPointer<FMGroup>
        var field: FMField

        init(core: [SDFShape], limbs: [SDFGroup]) {
            let all = [(core, SIMD3<Float>.zero, Float(0), Float(1), SIMD3<Float>.zero, Float(1e6))]
                + limbs.map { ($0.shapes, $0.joint, $0.blendK, $0.blendRadius, $0.boundCentre, $0.boundRadius) }
            shapes = all.map { group in
                let buffer = UnsafeMutableBufferPointer<FMShape>.allocate(capacity: max(group.0.count, 1))
                for (i, shape) in group.0.enumerated() { buffer[i] = shape.cShape }
                return buffer
            }
            groups = .allocate(capacity: all.count)
            for (i, group) in all.enumerated() {
                groups[i] = FMGroup(shapes: UnsafePointer(shapes[i].baseAddress), count: Int32(group.0.count),
                                    joint: (group.1.x, group.1.y, group.1.z), blendK: group.2, blendRadius: group.3,
                                    boundCentre: (group.4.x, group.4.y, group.4.z), boundRadius: group.5)
            }
            field = FMField(groups: UnsafePointer(groups.baseAddress), count: Int32(all.count))
        }

        deinit {
            shapes.forEach { $0.deallocate() }
            groups.deallocate()
        }
    }

    private let storage: Storage
    private let allShapes: [SDFShape]

    init(shapes: [SDFShape], limbs: [SDFGroup]) {
        storage = Storage(core: shapes, limbs: limbs)
        allShapes = shapes + limbs.flatMap(\.shapes)
    }

    func distance(_ p: SIMD3<Float>) -> Float {
        var point = (p.x, p.y, p.z)
        return withUnsafePointer(to: &storage.field) { field in
            withUnsafePointer(to: &point) { $0.withMemoryRebound(to: Float.self, capacity: 3) { fm_distance(field, $0) } }
        }
    }

    /// Which part produced the surface here: 0 for the torso and head, 1 + i for limb i.
    func part(at p: SIMD3<Float>) -> Int {
        var point = (p.x, p.y, p.z)
        return Int(withUnsafePointer(to: &storage.field) { field in
            withUnsafePointer(to: &point) { $0.withMemoryRebound(to: Float.self, capacity: 3) { fm_part(field, $0) } }
        })
    }

    /// Bounding box of every shape, with a margin.
    var bounds: (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for s in allShapes where s.op == .union {
            lo = simd_min(lo, s.boundCentre - s.boundRadius)
            hi = simd_max(hi, s.boundCentre + s.boundRadius)
        }
        lo.y = max(lo.y, -0.01)
        return (lo - 0.02, hi + 0.02)
    }

    fileprivate func withField<T>(_ body: (UnsafePointer<FMField>) -> T) -> T {
        withUnsafePointer(to: &storage.field, body)
    }
}

extension SDFShape {
    nonisolated var cShape: FMShape {
        var c = FMShape()
        c.op = op == .union ? Int32(FM_UNION) : Int32(FM_SUBTRACT)
        c.k = k
        c.boundCentre = (boundCentre.x, boundCentre.y, boundCentre.z)
        c.boundRadius = boundRadius
        switch kind {
        case .ellipsoid(let centre, let radii, let m):
            c.kind = Int32(FM_ELLIPSOID)
            c.centre = (centre.x, centre.y, centre.z)
            c.radii = (radii.x, radii.y, radii.z)
            // Row-major: element (row r, column k) is m[k][r].
            c.toLocal = (m[0][0], m[1][0], m[2][0], m[0][1], m[1][1], m[2][1], m[0][2], m[1][2], m[2][2])
        case .roundCone(let a, let b, let ra, let rb):
            c.kind = Int32(FM_ROUND_CONE)
            c.centre = (a.x, a.y, a.z)
            c.end = (b.x, b.y, b.z)
            c.ra = ra
            c.rb = rb
        case .cappedEllipsoid(let centre, let radii, let pp, let n, let capK):
            c.kind = Int32(FM_CAPPED_ELLIPSOID)
            c.centre = (centre.x, centre.y, centre.z)
            c.radii = (radii.x, radii.y, radii.z)
            c.planePoint = (pp.x, pp.y, pp.z)
            c.planeNormal = (n.x, n.y, n.z)
            c.capK = capK
        }
        return c
    }
}

nonisolated enum SurfaceNets {
    struct Mesh {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var indices: [UInt32]
    }

    /// Turns the field into one closed, consistently wound triangle mesh, with vertices projected onto the surface.
    static func mesh(_ field: BodyField, lo: SIMD3<Float>, hi: SIMD3<Float>, step h: Float) -> Mesh {
        var lower = (lo.x, lo.y, lo.z), upper = (hi.x, hi.y, hi.z)
        var raw = FMMesh()
        let status = field.withField { f in
            withUnsafePointer(to: &lower) { l in
                withUnsafePointer(to: &upper) { u in
                    l.withMemoryRebound(to: Float.self, capacity: 3) { lp in
                        u.withMemoryRebound(to: Float.self, capacity: 3) { up in fm_surface_nets(f, lp, up, h, &raw) }
                    }
                }
            }
        }
        defer { fm_mesh_free(&raw) }
        guard status == 0, raw.vertexCount > 0, let p = raw.positions, let n = raw.normals, let i = raw.indices else {
            return Mesh(positions: [], normals: [], indices: [])
        }
        let count = Int(raw.vertexCount)
        let positions = (0..<count).map { SIMD3<Float>(p[$0 * 3], p[$0 * 3 + 1], p[$0 * 3 + 2]) }
        let normals = (0..<count).map { SIMD3<Float>(n[$0 * 3], n[$0 * 3 + 1], n[$0 * 3 + 2]) }
        let indices = Array(UnsafeBufferPointer(start: i, count: Int(raw.indexCount)))
        return Mesh(positions: positions, normals: normals, indices: indices)
    }

    /// Area-weighted vertex normals from the triangles.
    static func meshNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let i0 = Int(indices[t]), i1 = Int(indices[t + 1]), i2 = Int(indices[t + 2])
            let n = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            normals[i0] += n; normals[i1] += n; normals[i2] += n
        }
        return normals.map { simd_length($0) > 1e-12 ? simd_normalize($0) : [0, 0, 1] }
    }
}

// MARK: - Face plate

/// The user's face, baked into a picture that is projected straight onto the front of the head, plus
/// (for a 3D scan) a depth map used to sculpt the head's surface into the scanned face.
/// Everything here is in metres relative to the head's origin.
nonisolated struct FacePlate: @unchecked Sendable {
    var image: CGImage
    var x0: Float, y0: Float, x1: Float, y1: Float
    var width: Int, height: Int
    /// How much of the face picture shows at each point (0 = plain skin). Fades out toward every edge.
    var alpha: [Float]
    var depth: [Float]?
    var depthWeight: [Float]?

    func uv(_ x: Float, _ y: Float) -> SIMD2<Float> {
        SIMD2<Float>((x - x0) / (x1 - x0), (y1 - y) / (y1 - y0))
    }

    func sample(_ grid: [Float], _ x: Float, _ y: Float) -> Float {
        let fx = (x - x0) / (x1 - x0) * Float(width) - 0.5
        let fy = (y1 - y) / (y1 - y0) * Float(height) - 0.5
        guard fx > -0.5, fy > -0.5, fx < Float(width) - 0.5, fy < Float(height) - 0.5 else { return 0 }
        let ix = min(max(Int(fx.rounded(.down)), 0), width - 2), iy = min(max(Int(fy.rounded(.down)), 0), height - 2)
        let tx = min(max(fx - Float(ix), 0), 1), ty = min(max(fy - Float(iy), 0), 1)
        let a = grid[iy * width + ix], b = grid[iy * width + ix + 1]
        let c = grid[(iy + 1) * width + ix], d = grid[(iy + 1) * width + ix + 1]
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    }

    /// Fades the face out below the hairline, so it meets the hair colour cleanly.
    private static func belowHairline(_ y: Float, scale s: Float) -> Float {
        1 - BodyMath.smoothstep(0.030 * s, 0.048 * s, y)
    }

    // MARK: Photo

    /// A cropped front-facing photo, feathered into the skin colour at its edges.
    static func photo(_ crop: CGImage, headScale s: Float, skin: SIMD3<Float>) -> FacePlate? {
        let x0 = -0.067 * s, x1 = 0.067 * s, y0 = -0.112 * s, y1 = 0.079 * s
        let w = 256, h = Int(Float(w) * (y1 - y0) / (x1 - x0))
        guard var pixels = rgba(of: crop, width: w, height: h) else { return nil }
        var alpha = [Float](repeating: 0, count: w * h)
        for py in 0..<h {
            let y = y1 - (Float(py) + 0.5) / Float(h) * (y1 - y0)
            for px in 0..<w {
                let u = (Float(px) + 0.5) / Float(w) * 2 - 1, v = (Float(py) + 0.5) / Float(h) * 2 - 1
                let rho = (u * u + v * v).squareRoot()
                alpha[py * w + px] = (1 - BodyMath.smoothstep(0.70, 0.97, rho)) * belowHairline(y, scale: s)
            }
        }
        blend(&pixels, alpha: alpha, skin: skin)
        guard let image = makeImage(pixels, width: w, height: h) else { return nil }
        return FacePlate(image: image, x0: x0, y0: y0, x1: x1, y1: y1, width: w, height: h, alpha: alpha)
    }

    // MARK: 3D scan

    /// The ARKit face scan, rasterised into a front view: the camera picture for the texture, and the scan's
    /// depth for sculpting the head. `surfaceZ` finds the generic head's front surface, to line the scan up with it.
    static func scan(_ data: FaceMeshData, texture: CGImage?, headScale s: Float, skin: SIMD3<Float>,
                     surfaceZ: (Float, Float) -> Float?) -> FacePlate? {
        let n = data.vertexCount
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        var points = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n {
            let p = SIMD3<Float>(data.vertices[i * 3], data.vertices[i * 3 + 1], data.vertices[i * 3 + 2])
            points[i] = p
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }
        // Centre the scan on the head, chin on chin.
        let shift = SIMD3<Float>(-(lo.x + hi.x) * 0.5, -0.106 * s - lo.y, 0)
        points = points.map { $0 + shift }
        guard let loop = outerLoop(indices: data.indices, points: points), loop.count >= 8 else { return nil }

        let x0 = lo.x + shift.x - 0.004, x1 = hi.x + shift.x + 0.004
        let y0 = lo.y + shift.y - 0.004, y1 = hi.y + shift.y + 0.004
        let w = 256, h = max(32, Int(Float(w) * (y1 - y0) / (x1 - x0)))
        func pixelX(_ x: Float) -> Float { (x - x0) / (x1 - x0) * Float(w) - 0.5 }
        func pixelY(_ y: Float) -> Float { (y1 - y) / (y1 - y0) * Float(h) - 0.5 }
        func worldX(_ px: Int) -> Float { x0 + (Float(px) + 0.5) / Float(w) * (x1 - x0) }
        func worldY(_ py: Int) -> Float { y1 - (Float(py) + 0.5) / Float(h) * (y1 - y0) }

        // Rasterise the scan's triangles: front-most depth and texture coordinate per pixel.
        let hasUV = data.uvs.count == n * 2
        var depth = [Float](repeating: 0, count: w * h)
        var us = [Float](repeating: 0, count: w * h), vs = [Float](repeating: 0, count: w * h)
        var filled = [Bool](repeating: false, count: w * h)
        for t in stride(from: 0, to: data.indices.count - 2, by: 3) {
            let i0 = Int(data.indices[t]), i1 = Int(data.indices[t + 1]), i2 = Int(data.indices[t + 2])
            let a = points[i0], b = points[i1], c = points[i2]
            let ax = pixelX(a.x), ay = pixelY(a.y), bx = pixelX(b.x), by = pixelY(b.y), cx = pixelX(c.x), cy = pixelY(c.y)
            let area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
            guard abs(area) > 1e-8 else { continue }
            let minX = max(Int(min(ax, bx, cx).rounded(.down)), 0), maxX = min(Int(max(ax, bx, cx).rounded(.up)), w - 1)
            let minY = max(Int(min(ay, by, cy).rounded(.down)), 0), maxY = min(Int(max(ay, by, cy).rounded(.up)), h - 1)
            guard minX <= maxX, minY <= maxY else { continue }
            for py in minY...maxY {
                for px in minX...maxX {
                    let fx = Float(px), fy = Float(py)
                    let wa = ((bx - fx) * (cy - fy) - (by - fy) * (cx - fx)) / area
                    let wb = ((cx - fx) * (ay - fy) - (cy - fy) * (ax - fx)) / area
                    let wc = 1 - wa - wb
                    guard wa >= -1e-4, wb >= -1e-4, wc >= -1e-4 else { continue }
                    let z = a.z * wa + b.z * wb + c.z * wc
                    let index = py * w + px
                    if filled[index], depth[index] >= z { continue }
                    filled[index] = true
                    depth[index] = z
                    if hasUV {
                        us[index] = data.uvs[i0 * 2] * wa + data.uvs[i1 * 2] * wb + data.uvs[i2 * 2] * wc
                        vs[index] = data.uvs[i0 * 2 + 1] * wa + data.uvs[i1 * 2 + 1] * wb + data.uvs[i2 * 2 + 1] * wc
                    }
                }
            }
        }
        let rasterised = filled

        // Fill the eye and mouth openings (and a band around the scan) from their neighbours.
        for _ in 0..<40 {
            var updates: [(Int, Float, Float, Float)] = []
            for py in 0..<h {
                for px in 0..<w where !filled[py * w + px] {
                    var sz: Float = 0, su: Float = 0, sv: Float = 0, count: Float = 0
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let qx = px + dx, qy = py + dy
                        guard qx >= 0, qy >= 0, qx < w, qy < h, filled[qy * w + qx] else { continue }
                        let q = qy * w + qx
                        sz += depth[q]; su += us[q]; sv += vs[q]; count += 1
                    }
                    if count > 0 { updates.append((py * w + px, sz / count, su / count, sv / count)) }
                }
            }
            if updates.isEmpty { break }
            for (index, z, u, v) in updates {
                depth[index] = z; us[index] = u; vs[index] = v; filled[index] = true
            }
        }

        // Feather toward the scan's outer edge.
        let polygon = loop.map { SIMD2<Float>(points[$0].x, points[$0].y) }
        var alpha = [Float](repeating: 0, count: w * h)
        var weight = [Float](repeating: 0, count: w * h)
        var edgeDistance = [Float](repeating: 0, count: w * h)
        for py in 0..<h {
            let y = worldY(py)
            for px in 0..<w {
                let p = SIMD2<Float>(worldX(px), y)
                guard contains(polygon, p) else { continue }
                let d = distance(polygon, p)
                let index = py * w + px
                edgeDistance[index] = d
                alpha[index] = BodyMath.smoothstep(0.002, 0.014, d) * belowHairline(y, scale: s)
                weight[index] = BodyMath.smoothstep(0.003, 0.022, d)
            }
        }

        // Line the scan up with the head: match depth over the cheeks and forehead, where both are smooth.
        var offsets: [Float] = []
        let stepX = 6, stepY = 6
        for py in stride(from: 0, to: h, by: stepY) {
            for px in stride(from: 0, to: w, by: stepX) {
                let index = py * w + px
                let x = worldX(px)
                guard rasterised[index], edgeDistance[index] > 0.02, abs(x) > 0.025 * s,
                      let head = surfaceZ(x, worldY(py)) else { continue }
                offsets.append(head - depth[index])
            }
        }
        guard offsets.count >= 10 else { return nil }
        offsets.sort()
        let dz = offsets[offsets.count / 2]
        for i in depth.indices { depth[i] += dz }

        // The camera picture, warped into the front view.
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        if let texture, hasUV, let camera = rgba(of: texture, width: texture.width, height: texture.height) {
            let cw = texture.width, ch = texture.height
            for index in 0..<(w * h) where alpha[index] > 0 {
                let fx = min(max(us[index], 0), 1) * Float(cw - 1), fy = min(max(vs[index], 0), 1) * Float(ch - 1)
                let ix = min(Int(fx), cw - 2), iy = min(Int(fy), ch - 2)
                let tx = fx - Float(ix), ty = fy - Float(iy)
                for channel in 0..<3 {
                    func c(_ x: Int, _ y: Int) -> Float { Float(camera[(y * cw + x) * 4 + channel]) }
                    let value = (c(ix, iy) * (1 - tx) + c(ix + 1, iy) * tx) * (1 - ty) + (c(ix, iy + 1) * (1 - tx) + c(ix + 1, iy + 1) * tx) * ty
                    pixels[index * 4 + channel] = UInt8(min(max(value, 0), 255))
                }
            }
        } else {
            // No picture: the scanned shape still sculpts the head, in plain skin.
            for i in alpha.indices { alpha[i] = 0 }
        }
        blend(&pixels, alpha: alpha, skin: skin)
        guard let image = makeImage(pixels, width: w, height: h) else { return nil }
        return FacePlate(image: image, x0: x0, y0: y0, x1: x1, y1: y1, width: w, height: h,
                         alpha: alpha, depth: depth, depthWeight: weight)
    }

    // MARK: Helpers

    /// The longest boundary loop of the scan: its outline, ignoring the eye and mouth openings.
    private static func outerLoop(indices: [UInt32], points: [SIMD3<Float>]) -> [Int]? {
        var edgeCount: [UInt64: Int] = [:]
        func key(_ a: Int, _ b: Int) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let v = [Int(indices[t]), Int(indices[t + 1]), Int(indices[t + 2])]
            for e in 0..<3 { edgeCount[key(v[e], v[(e + 1) % 3]), default: 0] += 1 }
        }
        var neighbours: [Int: [Int]] = [:]
        for (k, count) in edgeCount where count == 1 {
            let a = Int(k >> 32), b = Int(k & 0xffff_ffff)
            neighbours[a, default: []].append(b)
            neighbours[b, default: []].append(a)
        }
        var visited = Set<Int>()
        var best: [Int] = []
        var bestArea: Float = 0
        for start in neighbours.keys where !visited.contains(start) {
            var loop = [start]
            visited.insert(start)
            var previous = -1, current = start
            while let next = neighbours[current]?.first(where: { $0 != previous && !visited.contains($0) }) {
                loop.append(next)
                visited.insert(next)
                previous = current
                current = next
            }
            var area: Float = 0
            for i in loop.indices {
                let a = points[loop[i]], b = points[loop[(i + 1) % loop.count]]
                area += a.x * b.y - b.x * a.y
            }
            if abs(area) > bestArea { bestArea = abs(area); best = loop }
        }
        return best.isEmpty ? nil : best
    }

    private static func contains(_ polygon: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func distance(_ polygon: [SIMD2<Float>], _ p: SIMD2<Float>) -> Float {
        var best = Float.greatestFiniteMagnitude
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[j], b = polygon[i]
            let ab = b - a
            let t = min(max(simd_dot(p - a, ab) / max(simd_dot(ab, ab), 1e-12), 0), 1)
            best = min(best, simd_length(p - (a + ab * t)))
            j = i
        }
        return best
    }

    private static func blend(_ pixels: inout [UInt8], alpha: [Float], skin: SIMD3<Float>) {
        for i in alpha.indices {
            let a = alpha[i]
            for channel in 0..<3 {
                let value = Float(pixels[i * 4 + channel]) * a + skin[channel] * 255 * (1 - a)
                pixels[i * 4 + channel] = UInt8(min(max(value.rounded(), 0), 255))
            }
            pixels[i * 4 + 3] = 255
        }
    }

    /// Draws an image into an RGBA buffer of the given size; row 0 is the top of the picture.
    private static func rgba(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }

    private static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
