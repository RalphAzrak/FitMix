import SceneKit
import UIKit
import simd

/// What goes on the avatar's head.
nonisolated enum AvatarHead {
    /// Neutral head with no personal face.
    case template
    /// ARKit face geometry, with the camera crop as its texture when available.
    case mesh(FaceMeshData, texture: CGImage?)
    /// A cropped face photo on a standard head shape: a photo-based approximation.
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

/// Carries a finished node from the background thread that built it to the main thread that shows it.
nonisolated struct BuiltAvatar: @unchecked Sendable {
    let node: SCNNode
}

/// Poses for checking how the body deforms. `standing` is the bind pose, so it shows the mesh exactly as built.
nonisolated enum AvatarPose: String, Sendable, CaseIterable {
    case standing
    /// Left elbow bent 90° forward, right arm raised to the side with a bent elbow, left knee and hip bent.
    case jointTest
}

/// One bone of the avatar's skeleton. `head` is the joint the bone turns around.
nonisolated struct RigBone {
    var name: String
    var parent: Int
    var head: SIMD3<Float>
    var tail: SIMD3<Float>
    /// Rough radius of the body around this bone, used to decide which bone a vertex belongs to.
    var radius: Float
    /// Half-width of the band over which this bone's joint blends with its parent.
    var blend: Float
}

/// The body for one user: the distance field that describes its surface, its skeleton, and landmarks.
/// Units are metres; the figure faces +z and its soles rest on y = 0.
nonisolated struct BodyDesign {
    let height: Float
    let headScale: Float
    let headOrigin: SIMD3<Float>
    let field: BodyField
    let bones: [RigBone]
    let hemY: Float
    /// Where the neck rises from the torso (x, z), and the T-shirt's collar radius around it.
    let neckAxis: SIMD2<Float>
    let collarRadius: Float

    /// The bones of each field part, in the order of `BodyField.part(at:)`: torso, left arm, right arm, left leg, right leg.
    static let partBones: [[Int]] = [[0, 1, 2, 3, 4], [5, 6, 7], [8, 9, 10], [11, 12, 13], [14, 15, 16]]

    // Bone indices.
    static let hips = 0, spine = 1, chest = 2, neck = 3, head = 4
    static let upperArmL = 5, forearmL = 6, handL = 7, upperArmR = 8, forearmR = 9, handR = 10
    static let thighL = 11, shinL = 12, footL = 13, thighR = 14, shinR = 15, footR = 16

    init(shape: BodyShape, headScale s: Float) {
        let H = Float(shape.heightM)
        let g = Float(shape.girth)
        let sw = Float(shape.shoulderWidth), cw = Float(shape.chestWidth)
        let ww = Float(shape.waistWidth), hw = Float(shape.hipWidth)
        let chestD = 0.118 * H * g, waistD = 0.106 * H * pow(g, 1.25), hipD = 0.124 * H * g
        let armR = 0.0255 * H * pow(g, 0.85)
        let neckR = 0.032 * H * pow(g, 0.3)
        let headOrigin = SIMD3<Float>(0, H - 0.125 * s, 0.012 * H)
        func hp(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { headOrigin + SIMD3<Float>(x, y, z) * s }

        var shapes: [SDFShape] = []
        var limbs: [SDFGroup] = []

        // Torso: pelvis, waist, ribcage and shoulder girdle melt into one another.
        shapes.append(.ellipsoid([0, 0.515 * H, -0.006 * H], [hw * 0.5, 0.072 * H, hipD * 0.5], k: 0))
        for side: Float in [-1, 1] {
            shapes.append(.ellipsoid([side * hw * 0.21, 0.495 * H, -0.024 * H], [hw * 0.24, 0.055 * H, hipD * 0.32], k: 0.03 * H))
        }
        shapes.append(.ellipsoid([0, 0.605 * H, 0], [ww * 0.5, 0.075 * H, waistD * 0.5], k: 0.07 * H))
        shapes.append(.ellipsoid([0, 0.715 * H, 0], [cw * 0.5, 0.105 * H, chestD * 0.5], k: 0.07 * H))
        shapes.append(.ellipsoid([0, 0.787 * H, -0.008 * H], [sw * 0.5 - armR * 1.3, 0.036 * H, chestD * 0.40], k: 0.05 * H))
        for side: Float in [-1, 1] {   // trapezius: neck to shoulder
            shapes.append(.cone([side * neckR * 0.7, 0.836 * H, -0.014 * H], [side * (sw * 0.5 - armR * 1.45), 0.800 * H, -0.010 * H],
                                neckR * 0.85, armR * 0.85, k: 0.03 * H))
        }

        // Neck, from the shoulders up into the skull.
        let neckBase = SIMD3<Float>(0, 0.80 * H, -0.008 * H)
        shapes.append(.cone(neckBase, hp(0, -0.05, -0.022), neckR * 1.12, neckR, k: 0.03 * H))

        // Arms hang relaxed: a little away from the body, elbows slightly bent, palms toward the thighs.
        var shoulders: [SIMD3<Float>] = [], elbows: [SIMD3<Float>] = [], wrists: [SIMD3<Float>] = [], fingertips: [SIMD3<Float>] = []
        for side: Float in [1, -1] {
            let shoulder = SIMD3<Float>(side * (sw * 0.5 - armR * 1.2), 0.806 * H, -0.006 * H)
            // Held far enough from the hips that hand and hip never touch, so the two surfaces stay separate.
            let upperDir = simd_normalize(SIMD3<Float>(side * sin(0.2), -cos(0.2), 0))
            let elbow = shoulder + upperDir * 0.183 * H
            let foreDir = simd_normalize(upperDir + SIMD3<Float>(0, 0, 0.18))
            let wrist = elbow + foreDir * 0.145 * H
            let elbowR = 0.0215 * H * pow(g, 0.6), foreR = 0.0225 * H * pow(g, 0.7), wristR = 0.0135 * H * pow(g, 0.4)

            var arm: [SDFShape] = []
            arm.append(.ellipsoid(shoulder + SIMD3<Float>(side * 0.002 * H, 0.002 * H, 0),
                                  [armR * 1.04, armR * 1.16, armR * 1.06], k: 0))   // deltoid
            arm.append(.cone(shoulder, elbow, armR, elbowR, k: 0.03 * H))
            let foreMid = elbow + foreDir * 0.045 * H
            arm.append(.cone(elbow, foreMid, elbowR, foreR, k: 0.015 * H))
            arm.append(.cone(foreMid, wrist, foreR, wristR, k: 0.015 * H))

            // Hand: palm and fingers held together, thumb in front.
            let along = foreDir
            let across = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), along))
            let depth = simd_normalize(simd_cross(across, along))
            let axes = simd_float3x3(columns: (across, along, depth))
            arm.append(.ellipsoid(wrist + along * 0.042 * H, [0.0115 * H, 0.046 * H, 0.0255 * H], axes: axes, k: 0.012 * H))
            arm.append(.ellipsoid(wrist + along * 0.086 * H, [0.009 * H, 0.030 * H, 0.0215 * H], axes: axes, k: 0.010 * H))
            let forward = SIMD3<Float>(0, 0, 1)
            arm.append(.cone(wrist + along * 0.022 * H + forward * 0.012 * H, wrist + along * 0.062 * H + forward * 0.024 * H,
                             0.0085 * H, 0.0065 * H, k: 0.008 * H))
            limbs.append(SDFGroup(arm, joint: shoulder, blendK: 0.04 * H, blendRadius: 0.09 * H))

            shoulders.append(shoulder); elbows.append(elbow); wrists.append(wrist)
            fingertips.append(wrist + along * 0.11 * H)
        }

        // Legs and shoes.
        let thighR = min(0.05 * H * g, hw * 0.27)
        let hipX = max(hw * 0.5 - thighR * 0.98, thighR * 0.9)
        var hipJoints: [SIMD3<Float>] = [], knees: [SIMD3<Float>] = [], ankles: [SIMD3<Float>] = [], toes: [SIMD3<Float>] = []
        for side: Float in [1, -1] {
            let hip = SIMD3<Float>(side * hipX, 0.50 * H, 0)
            let knee = SIMD3<Float>(side * (0.052 * H + (hipX - 0.052 * H) * 0.38), 0.283 * H, 0.006 * H)
            let ankle = SIMD3<Float>(side * 0.054 * H, 0.05 * H, -0.006 * H)
            let kneeR = 0.0295 * H * pow(g, 0.6), ankleR = 0.0185 * H * pow(g, 0.4)
            var leg: [SDFShape] = []
            leg.append(.cone(hip + SIMD3<Float>(0, 0.02 * H, 0), knee, thighR, kneeR, k: 0))
            leg.append(.cone(knee, ankle, kneeR * 0.97, ankleR, k: 0.03 * H))
            leg.append(.ellipsoid(knee + (ankle - knee) * 0.32 + SIMD3<Float>(0, 0, -0.011 * H),
                                  SIMD3<Float>(0.026, 0.07, 0.024) * H * pow(g, 0.7), k: 0.035 * H))

            let turnOut: Float = 0.10
            let heel = SIMD3<Float>(ankle.x, 0.031 * H, -0.020 * H)
            let toe = SIMD3<Float>(ankle.x + side * 0.118 * H * sin(turnOut), 0.021 * H, -0.020 * H + 0.118 * H * cos(turnOut))
            leg.append(.cone(heel, toe, 0.031 * H, 0.023 * H, k: 0.022 * H))
            leg.append(.ellipsoid([ankle.x + side * 0.003 * H, 0.046 * H, 0.022 * H], [0.030 * H, 0.026 * H, 0.05 * H], k: 0.02 * H))
            leg.append(.ellipsoid([ankle.x, 0.062 * H, -0.010 * H], [0.025 * H, 0.026 * H, 0.029 * H], k: 0.02 * H))   // ankle collar
            limbs.append(SDFGroup(leg, joint: hip, blendK: 0.05 * H, blendRadius: 0.14 * H))

            hipJoints.append(hip); knees.append(knee); ankles.append(ankle); toes.append(toe)
        }

        // Head: skull, jaw, cheeks, brow, nose and ears, all one surface. Hair is a smooth cap over the top and back.
        let headK = 0.02 * H
        shapes.append(.ellipsoid(hp(0, 0.022, -0.014), SIMD3<Float>(0.075, 0.100, 0.098) * s, k: headK))
        shapes.append(.ellipsoid(hp(0, -0.045, 0.022), SIMD3<Float>(0.059, 0.066, 0.066) * s, k: 0.035 * s))
        shapes.append(.ellipsoid(hp(0, -0.090, 0.056), SIMD3<Float>(0.022, 0.017, 0.020) * s, k: 0.02 * s))
        for side: Float in [-1, 1] {
            shapes.append(.ellipsoid(hp(side * 0.038, -0.012, 0.055), SIMD3<Float>(0.026, 0.024, 0.024) * s, k: 0.02 * s))
        }
        shapes.append(.ellipsoid(hp(0, 0.028, 0.073), SIMD3<Float>(0.056, 0.014, 0.022) * s, k: 0.02 * s))
        shapes.append(.cone(hp(0, 0.006, 0.086), hp(0, -0.030, 0.101), 0.0075 * s, 0.0115 * s, k: 0.012 * s))
        for side: Float in [-1, 1] {
            shapes.append(.ellipsoid(hp(side * 0.074, 0.002, -0.012), SIMD3<Float>(0.011, 0.031, 0.019) * s, k: 0.006 * s))
        }
        shapes.append(.cappedEllipsoid(hp(0, 0.030, -0.018), SIMD3<Float>(0.080, 0.106, 0.104) * s,
                                       planePoint: hp(0, 0.055, 0.080), planeNormal: Self.hairNormal,
                                       capK: 0.01 * s, k: 0.008 * s))
        for side: Float in [-1, 1] {   // shallow eye sockets
            shapes.append(.ellipsoid(hp(side * 0.031, 0.009, 0.092), SIMD3<Float>(0.015, 0.009, 0.008) * s,
                                     k: 0.008 * s, op: .subtract))
        }

        field = BodyField(shapes: shapes, limbs: limbs)
        height = H
        headScale = s
        self.headOrigin = headOrigin
        hemY = 0.535 * H

        neckAxis = SIMD2<Float>(0, -0.009 * H)
        collarRadius = neckR * 1.55
        let headBase = hp(0, -0.06, -0.012)
        bones = [
            RigBone(name: "hips", parent: -1, head: [0, 0.50 * H, -0.004 * H], tail: [0, 0.585 * H, 0], radius: hw * 0.42, blend: 0),
            RigBone(name: "spine", parent: 0, head: [0, 0.585 * H, 0], tail: [0, 0.69 * H, 0], radius: ww * 0.46, blend: 0.045 * H),
            RigBone(name: "chest", parent: 1, head: [0, 0.69 * H, 0], tail: [0, 0.80 * H, -0.006 * H], radius: cw * 0.45, blend: 0.05 * H),
            RigBone(name: "neck", parent: 2, head: [0, 0.815 * H, -0.009 * H], tail: headBase, radius: neckR, blend: 0.022 * H),
            RigBone(name: "head", parent: 3, head: headBase, tail: hp(0, 0.10, -0.01), radius: 0.072 * s, blend: 0.022 * H),
            RigBone(name: "upperArm.L", parent: 2, head: shoulders[0], tail: elbows[0], radius: armR, blend: 0.024 * H),
            RigBone(name: "forearm.L", parent: 5, head: elbows[0], tail: wrists[0], radius: 0.02 * H, blend: 0.03 * H),
            RigBone(name: "hand.L", parent: 6, head: wrists[0], tail: fingertips[0], radius: 0.015 * H, blend: 0.014 * H),
            RigBone(name: "upperArm.R", parent: 2, head: shoulders[1], tail: elbows[1], radius: armR, blend: 0.024 * H),
            RigBone(name: "forearm.R", parent: 8, head: elbows[1], tail: wrists[1], radius: 0.02 * H, blend: 0.03 * H),
            RigBone(name: "hand.R", parent: 9, head: wrists[1], tail: fingertips[1], radius: 0.015 * H, blend: 0.014 * H),
            RigBone(name: "thigh.L", parent: 0, head: hipJoints[0], tail: knees[0], radius: thighR * 0.9, blend: 0.045 * H),
            RigBone(name: "shin.L", parent: 11, head: knees[0], tail: ankles[0], radius: 0.028 * H * g, blend: 0.05 * H),
            RigBone(name: "foot.L", parent: 12, head: ankles[0], tail: toes[0], radius: 0.022 * H, blend: 0.018 * H),
            RigBone(name: "thigh.R", parent: 0, head: hipJoints[1], tail: knees[1], radius: thighR * 0.9, blend: 0.045 * H),
            RigBone(name: "shin.R", parent: 14, head: knees[1], tail: ankles[1], radius: 0.028 * H * g, blend: 0.05 * H),
            RigBone(name: "foot.R", parent: 15, head: ankles[1], tail: toes[1], radius: 0.022 * H, blend: 0.018 * H),
        ]
    }

    /// Hair covers the side of this plane that faces up and back (in head-local, unscaled coordinates).
    static let hairNormal = simd_normalize(SIMD3<Float>(0, 0.17, -0.10))
    static let hairPoint = SIMD3<Float>(0, 0.055, 0.080)

    /// Positive above the hairline, negative on the face, in metres.
    func hairSide(_ p: SIMD3<Float>) -> Float {
        simd_dot((p - headOrigin) / headScale - Self.hairPoint, Self.hairNormal) * headScale
    }

    /// The front of the head at a point on the face, relative to the head origin; used to line up a face scan.
    func headSurfaceZ(_ x: Float, _ y: Float) -> Float? {
        var z: Float = 0.2 * headScale
        for _ in 0..<120 {
            let d = field.distance(headOrigin + SIMD3<Float>(x, y, z))
            if d < 0.0004 { return z }
            z -= max(d, 0.001)
            if z < -0.02 { return nil }
        }
        return nil
    }
}

/// Builds the avatar as one continuous, rigged SceneKit mesh. Nothing here touches the screen, so it runs off the main thread.
nonisolated enum AvatarBuilder {
    struct Palette {
        var skin: SIMD3<Float>
        var hair: SIMD3<Float>
        var top: SIMD3<Float>
        var bottoms: SIMD3<Float>
        var shoes: SIMD3<Float>
        var sole: SIMD3<Float>

        static func personalized(skin: SIMD3<Float>) -> Palette {
            Palette(skin: skin, hair: [0.17, 0.13, 0.11], top: [0.66, 0.73, 0.75], bottoms: [0.54, 0.62, 0.65],
                    shoes: [0.13, 0.13, 0.14], sole: [0.30, 0.30, 0.31])
        }

        /// Neutral greys, so a template is never mistaken for the user.
        static let template = Palette(skin: [0.76, 0.75, 0.73], hair: [0.56, 0.55, 0.54], top: [0.86, 0.86, 0.85],
                                      bottoms: [0.68, 0.68, 0.67], shoes: [0.42, 0.42, 0.42], sole: [0.55, 0.55, 0.55])
    }

    /// Grid spacing of the body mesh, in metres.
    static let resolution: Float = 0.005

    @concurrent
    static func build(_ content: AvatarContent, files: AvatarFiles) async -> BuiltAvatar {
        #if FM_BENCH
        let start = ContinuousClock.now
        #endif
        let head = AvatarHead.load(kind: content.faceKind, files: files)
        let node = makeAvatar(shape: content.shape, head: head)
        #if FM_BENCH
        let vertices = node.childNode(withName: "body", recursively: false)?.geometry?.sources(for: .vertex).first?.vectorCount ?? 0
        print("FM_TIMING build \(ContinuousClock.now - start) vertices \(vertices)")
        #endif
        return BuiltAvatar(node: node)
    }

    static func makeAvatar(shape: BodyShape, head: AvatarHead) -> SCNNode {
        let H = Float(shape.heightM)

        // Size the head: from the scan when there is one, so the scanned face fits it naturally.
        var headScale = min(max(H / 1.75, 0.93), 1.07)
        if case .mesh(let data, _) = head {
            var minX = Float.greatestFiniteMagnitude, maxX = -minX
            for i in 0..<data.vertexCount { minX = min(minX, data.vertices[i * 3]); maxX = max(maxX, data.vertices[i * 3]) }
            headScale = min(max((maxX - minX) / 0.150, 0.88), 1.14)
        }
        let design = BodyDesign(shape: shape, headScale: headScale)

        let palette: Palette
        let plate: FacePlate?
        switch head {
        case .template:
            palette = .template
            plate = nil
        case .photo(let image):
            palette = .personalized(skin: skinTone(image))
            plate = FacePlate.photo(image, headScale: headScale, skin: palette.skin)
        case .mesh(let data, let texture):
            palette = .personalized(skin: texture.map(skinTone) ?? [0.80, 0.63, 0.52])
            plate = FacePlate.scan(data, texture: texture, headScale: headScale, skin: palette.skin,
                                   surfaceZ: design.headSurfaceZ)
        }

        let bounds = design.field.bounds
        var mesh = SurfaceNets.mesh(design.field, lo: bounds.lo, hi: bounds.hi, step: resolution)
        let count = mesh.positions.count
        let closest = mesh.positions.map { p in
            closestBone(p, among: BodyDesign.partBones[design.field.part(at: p)], design.bones)
        }

        // Sculpt the front of the head into the scanned face, fading out toward its edges.
        if let plate, let depth = plate.depth, let weight = plate.depthWeight {
            var displaced: [Int] = []
            for i in 0..<count where closest[i] == BodyDesign.head || closest[i] == BodyDesign.neck {
                let rel = mesh.positions[i] - design.headOrigin
                guard rel.z > 0 else { continue }
                let w = plate.sample(weight, rel.x, rel.y)
                guard w > 0.001 else { continue }
                let target = plate.sample(depth, rel.x, rel.y)
                guard abs(target - rel.z) < 0.04 else { continue }
                mesh.positions[i].z += (target - rel.z) * w
                displaced.append(i)
            }
            if !displaced.isEmpty {
                let fresh = SurfaceNets.meshNormals(positions: mesh.positions, indices: mesh.indices)
                for i in displaced { mesh.normals[i] = fresh[i] }
            }
        }

        let weights = mesh.positions.indices.map { skinWeights(mesh.positions[$0], closest: closest[$0], design.bones) }
        let colours = mesh.positions.indices.map { colour(mesh.positions[$0], bone: closest[$0], design: design, palette: palette) }

        // Triangles that show the face picture. Their vertices are duplicated so the face can use its own
        // texture; the copies share position, normal and skin weights, so the surface stays continuous.
        var isFace = [Bool](repeating: false, count: count)
        if let plate {
            for i in 0..<count where closest[i] == BodyDesign.head {
                let rel = mesh.positions[i] - design.headOrigin
                isFace[i] = rel.z > 0.02 * headScale && plate.sample(plate.alpha, rel.x, rel.y) > 0.002
            }
        }
        var bodyIndices: [UInt32] = [], faceIndices: [UInt32] = []
        var faceCopy: [Int: UInt32] = [:]
        var positions = mesh.positions, normals = mesh.normals
        var vertexColours = colours, vertexWeights = weights
        var uvs = [CGPoint](repeating: .zero, count: count)
        bodyIndices.reserveCapacity(mesh.indices.count)
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let tri = [Int(mesh.indices[t]), Int(mesh.indices[t + 1]), Int(mesh.indices[t + 2])]
            guard let plate, isFace[tri[0]], isFace[tri[1]], isFace[tri[2]] else {
                bodyIndices += [mesh.indices[t], mesh.indices[t + 1], mesh.indices[t + 2]]
                continue
            }
            for v in tri {
                if let copy = faceCopy[v] { faceIndices.append(copy); continue }
                let copy = UInt32(positions.count)
                faceCopy[v] = copy
                positions.append(positions[v]); normals.append(normals[v]); vertexWeights.append(vertexWeights[v])
                vertexColours.append([1, 1, 1])
                let rel = positions[v] - design.headOrigin
                let uv = plate.uv(rel.x, rel.y)
                uvs.append(CGPoint(x: CGFloat(uv.x), y: CGFloat(uv.y)))
                faceIndices.append(copy)
            }
        }

        // Geometry.
        let n = positions.count
        var colourData = [Float](), weightData = [Float](), boneIndexData = [UInt16]()
        colourData.reserveCapacity(n * 3); weightData.reserveCapacity(n * 4); boneIndexData.reserveCapacity(n * 4)
        for i in 0..<n {
            // SceneKit shades in linear colour; the palette is written in sRGB.
            let c = vertexColours[i]
            colourData += [pow(c.x, 2.2), pow(c.y, 2.2), pow(c.z, 2.2)]
            let w = vertexWeights[i]
            for j in 0..<4 {
                weightData.append(w[j].weight)
                boneIndexData.append(UInt16(w[j].bone))
            }
        }
        let sources = [
            SCNGeometrySource(vertices: positions.map { SCNVector3($0) }),
            SCNGeometrySource(normals: normals.map { SCNVector3($0) }),
            SCNGeometrySource(textureCoordinates: uvs),
            SCNGeometrySource(data: colourData.withUnsafeBytes { Data($0) }, semantic: .color, vectorCount: n,
                              usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12),
        ]
        var elements = [SCNGeometryElement(indices: bodyIndices, primitiveType: .triangles)]
        var materials = [material(texture: nil)]
        if let plate, !faceIndices.isEmpty {
            elements.append(SCNGeometryElement(indices: faceIndices, primitiveType: .triangles))
            materials.append(material(texture: plate.image))
        }
        let geometry = SCNGeometry(sources: sources, elements: elements)
        geometry.materials = materials

        // Skeleton, in the bind pose.
        let boneNodes = design.bones.map { bone -> SCNNode in
            let node = SCNNode()
            node.name = bone.name
            return node
        }
        for (i, bone) in design.bones.enumerated() {
            if bone.parent >= 0 {
                boneNodes[bone.parent].addChildNode(boneNodes[i])
                boneNodes[i].simdPosition = bone.head - design.bones[bone.parent].head
            } else {
                boneNodes[i].simdPosition = bone.head
            }
        }
        let inverseBinds = design.bones.map { NSValue(scnMatrix4: SCNMatrix4MakeTranslation(-$0.head.x, -$0.head.y, -$0.head.z)) }
        let weightSource = SCNGeometrySource(data: weightData.withUnsafeBytes { Data($0) }, semantic: .boneWeights, vectorCount: n,
                                             usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4,
                                             dataOffset: 0, dataStride: 16)
        let indexSource = SCNGeometrySource(data: boneIndexData.withUnsafeBytes { Data($0) }, semantic: .boneIndices, vectorCount: n,
                                            usesFloatComponents: false, componentsPerVector: 4, bytesPerComponent: 2,
                                            dataOffset: 0, dataStride: 8)
        let skinner = SCNSkinner(baseGeometry: geometry, bones: boneNodes, boneInverseBindTransforms: inverseBinds,
                                 boneWeights: weightSource, boneIndices: indexSource)
        skinner.skeleton = boneNodes[0]

        let body = SCNNode(geometry: geometry)
        body.name = "body"
        body.skinner = skinner

        let root = SCNNode()
        root.name = "avatar"
        root.addChildNode(boneNodes[0])
        root.addChildNode(body)
        return root
    }

    // MARK: Poses

    static func apply(_ pose: AvatarPose, to avatar: SCNNode) {
        func set(_ name: String, _ rotation: simd_quatf) {
            avatar.childNode(withName: name, recursively: true)?.simdOrientation = rotation
        }
        let identity = simd_quatf(angle: 0, axis: [0, 1, 0])
        for name in ["upperArm.L", "forearm.L", "upperArm.R", "forearm.R", "thigh.L", "shin.L", "thigh.R", "shin.R", "spine", "neck"] {
            set(name, identity)
        }
        guard pose == .jointTest else { return }
        set("upperArm.L", simd_quatf(angle: -0.45, axis: [1, 0, 0]))
        set("forearm.L", simd_quatf(angle: -1.55, axis: [1, 0, 0]))
        set("upperArm.R", simd_quatf(angle: -1.2, axis: [0, 0, 1]))
        set("forearm.R", simd_quatf(angle: -1.1, axis: [1, 0, 0]))
        set("thigh.L", simd_quatf(angle: -0.55, axis: [1, 0, 0]))
        set("shin.L", simd_quatf(angle: 0.95, axis: [1, 0, 0]))
    }

    // MARK: Skinning

    /// The nearest bone within the body part that produced this bit of surface, so a hand resting near the hip
    /// never claims the hip's skin.
    private static func closestBone(_ p: SIMD3<Float>, among candidates: [Int], _ bones: [RigBone]) -> Int {
        var best = candidates[0]
        var bestDistance = Float.greatestFiniteMagnitude
        for i in candidates {
            let bone = bones[i]
            let d = BodyMath.distanceToSegment(p, bone.head, bone.tail) - bone.radius
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    /// Up to four bone influences. Each joint blends smoothly between its parent and child bone across a band
    /// around the joint, so the skin bends instead of creasing.
    private static func skinWeights(_ p: SIMD3<Float>, closest b: Int, _ bones: [RigBone]) -> [(bone: Int, weight: Float)] {
        var weights: [Int: Float] = [b: 1]
        let bone = bones[b]
        if bone.parent >= 0 {
            let direction = simd_normalize(bone.tail - bone.head)
            let s = simd_dot(p - bone.head, direction)
            let f = BodyMath.smoothstep(-bone.blend, bone.blend, s)
            weights[b] = f
            weights[bone.parent, default: 0] += 1 - f
        }
        for (c, child) in bones.enumerated() where child.parent == b {
            let direction = simd_normalize(child.tail - child.head)
            let rel = p - child.head
            let s = simd_dot(rel, direction)
            guard s > -child.blend else { continue }
            // Along a limb (knee, elbow, wrist, ankle) the whole cross-section blends. Where a limb branches off the
            // torso (shoulder, hip) only the skin close to the limb follows it, so the torso side stays put.
            let branches = c == BodyDesign.upperArmL || c == BodyDesign.upperArmR || c == BodyDesign.thighL || c == BodyDesign.thighR
            let across = simd_length(rel - direction * s)
            let reach = branches ? 1 - BodyMath.smoothstep(child.radius * 1.1, child.radius * 1.4, across) : 1
            let f = BodyMath.smoothstep(-child.blend, child.blend, s) * reach
            guard f > 0 else { continue }
            let own = weights[b] ?? 0
            weights[c, default: 0] += own * f
            weights[b] = own * (1 - f)
        }
        var sorted = weights.filter { $0.value > 1e-4 }.sorted { $0.value > $1.value }.prefix(4).map { (bone: $0.key, weight: $0.value) }
        let total = sorted.reduce(0) { $0 + $1.weight }
        for i in sorted.indices { sorted[i].weight /= max(total, 1e-6) }
        while sorted.count < 4 { sorted.append((bone: 0, weight: 0)) }
        return sorted
    }

    // MARK: Colour

    /// Skin, hair, a fitted T-shirt, slim trousers and shoes, painted on the one surface with soft edges.
    private static func colour(_ p: SIMD3<Float>, bone: Int, design: BodyDesign, palette: Palette) -> SIMD3<Float> {
        let H = design.height
        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
        let shoeLine = 1 - BodyMath.smoothstep(0.072 * H, 0.078 * H, p.y)
        let soleLine = 1 - BodyMath.smoothstep(0.008 * H, 0.012 * H, p.y)
        let shoe = mix(palette.shoes, palette.sole, soleLine)
        switch bone {
        case BodyDesign.head:
            return mix(palette.skin, palette.hair, BodyMath.smoothstep(-0.004, 0.004, design.hairSide(p)))
        case BodyDesign.neck, BodyDesign.chest:
            // Crew collar around the base of the neck, scooped a little lower at the front.
            guard p.y > 0.76 * H else { return palette.top }
            let fromNeck = simd_length(SIMD2<Float>(p.x, p.z) - design.neckAxis)
            let back = 1 - 0.22 * BodyMath.smoothstep(0, 0.03 * H, design.neckAxis.y - p.z)
            let collar = design.collarRadius * back + 0.012 * H * min(max(p.z / (0.05 * H), 0), 1) * BodyMath.smoothstep(0.80 * H, 0.83 * H, p.y)
            let skin = (1 - BodyMath.smoothstep(collar - 0.003 * H, collar + 0.003 * H, fromNeck)) * BodyMath.smoothstep(0.80 * H, 0.806 * H, p.y)
            return mix(palette.top, palette.skin, skin)
        case BodyDesign.spine, BodyDesign.hips:
            return mix(palette.bottoms, palette.top, BodyMath.smoothstep(design.hemY - 0.005 * H, design.hemY + 0.005 * H, p.y))
        case BodyDesign.upperArmL, BodyDesign.upperArmR:
            let arm = design.bones[bone]
            let t = simd_dot(p - arm.head, simd_normalize(arm.tail - arm.head)) / simd_length(arm.tail - arm.head)
            return mix(palette.top, palette.skin, BodyMath.smoothstep(0.40, 0.44, t))
        case BodyDesign.forearmL, BodyDesign.forearmR, BodyDesign.handL, BodyDesign.handR:
            return palette.skin
        case BodyDesign.thighL, BodyDesign.thighR, BodyDesign.shinL, BodyDesign.shinR, BodyDesign.footL, BodyDesign.footR:
            return mix(palette.bottoms, shoe, shoeLine)
        default:
            return palette.skin
        }
    }

    private static func skinTone(_ image: CGImage) -> SIMD3<Float> {
        guard let colour = image.averageCentreColor() else { return [0.80, 0.63, 0.52] }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Float(r), Float(g), Float(b)]
    }

    private static func material(texture: CGImage?) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = texture ?? UIColor.white
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.specular.contents = UIColor(white: 0.07, alpha: 1)
        m.shininess = 0.12
        return m
    }
}
