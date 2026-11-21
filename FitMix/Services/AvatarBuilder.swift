import RealityKit
import UIKit
import simd

/// What goes on the avatar's head.
enum AvatarHead {
    /// Plain mannequin head.
    case template
    /// ARKit face geometry, with the camera crop as its texture when available.
    case mesh(FaceMeshData, texture: CGImage?)
    /// A cropped face photo placed on a generic head: a photo-based approximation.
    case photo(CGImage)

    static func load(kind: FaceCaptureKind?, files: AvatarFiles) -> AvatarHead {
        let texture = UIImage(contentsOfFile: files.faceTexture.path)?.cgImage
        switch kind {
        case .mesh:
            guard let mesh = AvatarStore.loadFaceMesh(from: files), mesh.isValid else { return .template }
            return .mesh(mesh, texture: texture)
        case .photo:
            guard let texture else { return .template }
            return .photo(texture)
        case nil:
            return .template
        }
    }
}

/// Builds the avatar as RealityKit geometry: a parametric body scaled to the user's
/// proportions, with the captured face on the head. Units are metres; feet rest on y = 0.
enum AvatarBuilder {
    static let mannequinColor = UIColor(red: 0.66, green: 0.64, blue: 0.61, alpha: 1)

    static func makeAvatar(shape: BodyShape, head: AvatarHead) -> Entity {
        let root = Entity()
        let H = Float(shape.heightM)
        let g = Float(shape.girth)
        let body = material(mannequinColor)

        let sw = Float(shape.shoulderWidth), cw = Float(shape.chestWidth)
        let ww = Float(shape.waistWidth), hw = Float(shape.hipWidth)
        let chestD = 0.118 * H * g, waistD = 0.108 * H * pow(g, 1.25), hipD = 0.128 * H * g
        let neckR = 0.031 * H * pow(g, 0.3)
        let armR = 0.027 * H * pow(g, 0.9)

        // Torso and neck.
        let torso: [Ring] = [
            Ring(y: 0.452 * H, rx: hw * 0.22, rz: hipD * 0.30),
            Ring(y: 0.475 * H, rx: hw * 0.44, rz: hipD * 0.44),
            Ring(y: 0.520 * H, rx: hw * 0.50, rz: hipD * 0.50),
            Ring(y: 0.565 * H, rx: (hw + ww) * 0.25, rz: (hipD + waistD) * 0.25),
            Ring(y: 0.615 * H, rx: ww * 0.50, rz: waistD * 0.50),
            Ring(y: 0.675 * H, rx: (ww * 0.35 + cw * 0.65) * 0.5, rz: (waistD * 0.3 + chestD * 0.7) * 0.5),
            Ring(y: 0.735 * H, rx: cw * 0.50, rz: chestD * 0.50),
            Ring(y: 0.782 * H, rx: max(sw * 0.5 - armR * 0.9, cw * 0.48), rz: chestD * 0.48),
            Ring(y: 0.808 * H, rx: max(sw * 0.5 - armR * 1.1, cw * 0.44), rz: chestD * 0.40),
            Ring(y: 0.826 * H, rx: sw * 0.27, rz: chestD * 0.30),
            Ring(y: 0.838 * H, rx: neckR * 1.5, rz: neckR * 1.3),
            Ring(y: 0.848 * H, rx: neckR * 1.05, rz: neckR * 1.05),
            Ring(y: 0.885 * H, rx: neckR, rz: neckR),
        ]
        addLoft(torso, material: body, to: root)

        // Legs and feet.
        let thighR = min(hw * 0.262, 0.05 * H * g)
        let hipX = max(hw * 0.5 - thighR, thighR * 0.98)
        let ankleX = 0.05 * H
        let ankleR = 0.019 * H * pow(g, 0.4)
        for side: Float in [-1, 1] {
            func x(_ y: Float) -> Float { side * (ankleX + (hipX - ankleX) * min(max((y - 0.04) / 0.46, 0), 1)) }
            let leg: [Ring] = [
                Ring(y: 0.035 * H, r: ankleR * 0.9, cx: x(0.035)),
                Ring(y: 0.060 * H, r: ankleR, cx: x(0.06)),
                Ring(y: 0.140 * H, r: 0.024 * H * pow(g, 0.6), cx: x(0.14)),
                Ring(y: 0.210 * H, r: 0.032 * H * pow(g, 0.8), cx: x(0.21), cz: -0.004 * H),
                Ring(y: 0.285 * H, r: 0.029 * H * pow(g, 0.6), cx: x(0.285)),
                Ring(y: 0.380 * H, r: min(0.040 * H * g, thighR), cx: x(0.38)),
                Ring(y: 0.450 * H, r: thighR, cx: x(0.45)),
                Ring(y: 0.500 * H, r: thighR * 0.92, cx: x(0.50)),
            ]
            addLoft(leg, material: body, to: root)
            addEllipsoid(radii: [0.027 * H, 0.021 * H, 0.074 * H], at: [side * ankleX, 0.021 * H, 0.034 * H],
                         material: body, to: root)
        }

        // Arms, held slightly away from the body.
        for side: Float in [-1, 1] {
            let arm = Entity()
            arm.position = [side * (sw * 0.5 - armR), 0.788 * H, 0]
            arm.orientation = simd_quatf(angle: side * 0.16, axis: [0, 0, 1])
            let rings: [Ring] = [
                Ring(y: -0.335 * H, r: 0.0135 * H * pow(g, 0.4)),
                Ring(y: -0.300 * H, r: 0.017 * H * pow(g, 0.5)),
                Ring(y: -0.235 * H, r: 0.0225 * H * pow(g, 0.7)),
                Ring(y: -0.186 * H, r: 0.0205 * H * pow(g, 0.6)),
                Ring(y: -0.100 * H, r: 0.0255 * H * pow(g, 0.9)),
                Ring(y: -0.020 * H, r: armR),
                Ring(y: 0, r: armR * 0.9),
            ]
            addLoft(rings, material: body, to: arm)
            addEllipsoid(radii: [armR, armR, armR], at: .zero, material: body, to: arm)
            addEllipsoid(radii: [0.021 * H, 0.048 * H, 0.012 * H], at: [0, -0.380 * H, 0], material: body, to: arm)
            root.addChild(arm)
        }

        root.addChild(makeHead(head, height: H))
        return root
    }

    // MARK: Head

    private static func makeHead(_ head: AvatarHead, height H: Float) -> Entity {
        let group = Entity()
        let chinY = 0.868 * H
        let headZ = 0.012 * H

        switch head {
        case .mesh(let data, let texture):
            let count = data.vertexCount
            var positions = [SIMD3<Float>]()
            positions.reserveCapacity(count)
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for i in 0..<count {
                let p = SIMD3<Float>(data.vertices[i * 3], data.vertices[i * 3 + 1], data.vertices[i * 3 + 2])
                positions.append(p)
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
            let width = hi.x - lo.x
            let s = min(max(width / 0.146, 0.85), 1.15)
            let skinTone = texture?.averageCentreColor()

            // A plain skull behind the scanned face, sized from the scan.
            let top = lo.y + 0.232 * s, bottom = lo.y + 0.015
            let radii = SIMD3<Float>(width * 0.5 * 1.07, (top - bottom) * 0.5, 0.096 * s)
            let centre = SIMD3<Float>((lo.x + hi.x) * 0.5, (top + bottom) * 0.5, lo.z - 0.040 * s)
            addEllipsoid(radii: radii, at: centre, material: material(skinTone ?? mannequinColor), to: group)

            var normals = smoothNormals(positions: positions, indices: data.indices)
            var indices = data.indices
            // The face looks along +z. If the normals disagree, the winding is the other way round.
            if normals.reduce(0, { $0 + $1.z }) < 0 {
                normals = normals.map { -$0 }
                for t in stride(from: 0, to: indices.count - 2, by: 3) { indices.swapAt(t + 1, t + 2) }
            }
            var descriptor = MeshDescriptor(name: "face")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.normals = MeshBuffers.Normals(normals)
            descriptor.primitives = .triangles(indices)
            var faceMaterial = material(skinTone ?? mannequinColor)
            if let texture, data.uvs.count == count * 2 {
                descriptor.textureCoordinates = MeshBuffers.TextureCoordinates((0..<count).map {
                    SIMD2<Float>(data.uvs[$0 * 2], 1 - data.uvs[$0 * 2 + 1])
                })
                faceMaterial = material(.white, texture: texture)
            }
            if let mesh = try? MeshResource.generate(from: [descriptor]) {
                group.addChild(ModelEntity(mesh: mesh, materials: [faceMaterial]))
            }
            group.position = [-centre.x, chinY - lo.y, headZ - centre.z]

        case .photo(let image):
            let s = min(max(H / 1.75, 0.9), 1.1)
            let radii = SIMD3<Float>(0.076, 0.115, 0.096) * s
            let skinTone = image.averageCentreColor() ?? mannequinColor
            addEllipsoid(radii: radii, at: .zero, material: material(skinTone), to: group)
            if let patch = facePatch(radii: radii, scale: s) {
                group.addChild(ModelEntity(mesh: patch, materials: [material(.white, texture: image)]))
            }
            group.position = [0, chinY + radii.y, headZ]

        case .template:
            let s = min(max(H / 1.75, 0.9), 1.1)
            let radii = SIMD3<Float>(0.076, 0.115, 0.096) * s
            addEllipsoid(radii: radii, at: .zero, material: material(mannequinColor), to: group)
            group.position = [0, chinY + radii.y, headZ]
        }
        return group
    }

    /// An elliptical patch on the front of the head that carries the face photo.
    private static func facePatch(radii: SIMD3<Float>, scale s: Float) -> MeshResource? {
        let a = 0.060 * s
        let b = a / Float(FacePhotoProcessor.cropAspect)
        let centreY = -0.012 * s
        let ringCount = 10, spokes = 40
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for r in 0...ringCount {
            let t = Float(r) / Float(ringCount)
            for k in 0..<spokes {
                let angle = Float(k) / Float(spokes) * 2 * .pi
                let x = a * t * cos(angle)
                let y = centreY + b * t * sin(angle)
                let inside = max(0, 1 - (x * x) / (radii.x * radii.x) - (y * y) / (radii.y * radii.y))
                let z = radii.z * inside.squareRoot()
                let n = simd_normalize(SIMD3<Float>(x / (radii.x * radii.x), y / (radii.y * radii.y), z / (radii.z * radii.z)))
                positions.append(SIMD3<Float>(x, y, z) + n * 0.0015)
                normals.append(n)
                uvs.append(SIMD2<Float>(0.5 + 0.5 * t * cos(angle), 0.5 + 0.5 * t * sin(angle)))
            }
        }
        for r in 0..<ringCount {
            for k in 0..<spokes {
                let k1 = (k + 1) % spokes
                let i0 = UInt32(r * spokes + k), i1 = UInt32(r * spokes + k1)
                let o0 = UInt32((r + 1) * spokes + k), o1 = UInt32((r + 1) * spokes + k1)
                indices += [i0, o0, o1, i0, o1, i1]
            }
        }
        var descriptor = MeshDescriptor(name: "facePatch")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    // MARK: Geometry helpers

    /// One elliptical cross-section of a lofted limb or torso.
    struct Ring {
        var y: Float
        var rx: Float
        var rz: Float
        var cx: Float = 0
        var cz: Float = 0

        init(y: Float, rx: Float, rz: Float, cx: Float = 0, cz: Float = 0) {
            self.y = y; self.rx = rx; self.rz = rz; self.cx = cx; self.cz = cz
        }

        init(y: Float, r: Float, cx: Float = 0, cz: Float = 0) {
            self.init(y: y, rx: r, rz: r, cx: cx, cz: cz)
        }

        var vector: SIMD8<Float> { [y, rx, rz, cx, cz, 0, 0, 0] }
        init(_ v: SIMD8<Float>) { self.init(y: v[0], rx: max(v[1], 0.0005), rz: max(v[2], 0.0005), cx: v[3], cz: v[4]) }
    }

    private static func material(_ color: UIColor, texture: CGImage? = nil) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        if let texture, let resource = try? TextureResource(image: texture, options: .init(semantic: .color)) {
            m.baseColor = .init(tint: .white, texture: .init(resource))
        } else {
            m.baseColor = .init(tint: color)
        }
        m.roughness = 0.82
        m.metallic = 0.0
        m.faceCulling = .none
        return m
    }

    private static func addEllipsoid(radii: SIMD3<Float>, at position: SIMD3<Float>, material: PhysicallyBasedMaterial, to parent: Entity) {
        let entity = ModelEntity(mesh: .generateSphere(radius: 1), materials: [material])
        entity.scale = radii
        entity.position = position
        parent.addChild(entity)
    }

    private static func addLoft(_ rings: [Ring], material: PhysicallyBasedMaterial, to parent: Entity) {
        guard let mesh = loft(rings) else { return }
        parent.addChild(ModelEntity(mesh: mesh, materials: [material]))
    }

    /// Skins a smooth surface through the rings (Catmull-Rom between them) and caps both ends.
    private static func loft(_ control: [Ring], segments: Int = 32, subdivisions: Int = 6) -> MeshResource? {
        guard control.count >= 2 else { return nil }
        var rings: [Ring] = []
        for i in 0..<(control.count - 1) {
            let p0 = control[max(i - 1, 0)].vector, p1 = control[i].vector
            let p2 = control[i + 1].vector, p3 = control[min(i + 2, control.count - 1)].vector
            for s in 0..<subdivisions {
                let t = Float(s) / Float(subdivisions)
                let t2 = t * t, t3 = t2 * t
                let a = p1 * 2
                let b = (p2 - p0) * t
                let c = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
                let d = (p1 * 3 - p0 - p2 * 3 + p3) * t3
                rings.append(Ring((a + b + c + d) * 0.5))
            }
        }
        rings.append(control[control.count - 1])

        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let columns = segments + 1
        for (i, ring) in rings.enumerated() {
            let before = rings[max(i - 1, 0)], after = rings[min(i + 1, rings.count - 1)]
            for j in 0...segments {
                let angle = Float(j) / Float(segments) * 2 * .pi
                let c = cos(angle), s = sin(angle)
                positions.append([ring.cx + ring.rx * c, ring.y, ring.cz + ring.rz * s])
                let around = SIMD3<Float>(-ring.rx * s, 0, ring.rz * c)
                let along = SIMD3<Float>((after.cx + after.rx * c) - (before.cx + before.rx * c), after.y - before.y,
                                         (after.cz + after.rz * s) - (before.cz + before.rz * s))
                var n = simd_cross(along, around)
                n = simd_length(n) > 1e-8 ? simd_normalize(n) : SIMD3<Float>(c, 0, s)
                if simd_dot(n, SIMD3<Float>(c, 0, s)) < 0 { n = -n }
                normals.append(n)
            }
        }
        for i in 0..<(rings.count - 1) {
            for j in 0..<segments {
                let a = UInt32(i * columns + j), b = a + 1
                let c = UInt32((i + 1) * columns + j), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        // End caps.
        for (ringIndex, ny) in [(0, Float(-1)), (rings.count - 1, Float(1))] {
            let ring = rings[ringIndex]
            let centreIndex = UInt32(positions.count)
            positions.append([ring.cx, ring.y, ring.cz])
            normals.append([0, ny, 0])
            let start = UInt32(positions.count)
            for j in 0...segments {
                let angle = Float(j) / Float(segments) * 2 * .pi
                positions.append([ring.cx + ring.rx * cos(angle), ring.y, ring.cz + ring.rz * sin(angle)])
                normals.append([0, ny, 0])
            }
            for j in 0..<UInt32(segments) { indices += [centreIndex, start + j, start + j + 1] }
        }

        var descriptor = MeshDescriptor(name: "loft")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    private static func smoothNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let i0 = Int(indices[t]), i1 = Int(indices[t + 1]), i2 = Int(indices[t + 2])
            let n = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            normals[i0] += n; normals[i1] += n; normals[i2] += n
        }
        return normals.map { simd_length($0) > 1e-12 ? simd_normalize($0) : SIMD3<Float>(0, 0, 1) }
    }
}
