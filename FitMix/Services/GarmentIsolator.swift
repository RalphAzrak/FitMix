import CoreImage
import CoreVideo
import OSLog
import UIKit
import Vision

// MARK: - On-device garment isolation
//
// Runs on the confirmed Camera still, entirely on this iPhone (Vision, no network). Vision has no
// clothing segmentation, so this isolates garments by body region:
//  1. `VNGeneratePersonInstanceMaskRequest` separates each person; the largest one is used. Its
//     coarse mask is refined with `VNGeneratePersonSegmentationRequest` (.accurate) and reduced to
//     the connected area around the torso, which drops stray patches.
//  2. `VNDetectHumanBodyPoseRequest` finds that person's shoulders, hips, knees, and ankles.
//  3. The person's mask is split at those joints into a Top (shoulders → hips, arms included)
//     and Bottoms (hips → ankles, within the legs' width).
// Each region becomes a transparent cutout and a rectangular crop of the same photo, with bounds
// normalized to that photo, so outlines and cutouts line up in Studio and Outfit Review.
// Limits: skin inside a region (bare arms, legs below shorts) is part of its cutout, and the split
// is at the hip joint, so long tops or high-waisted bottoms are cut there. A clothing-parsing
// model can replace `regions(...)` later without changing the output.

nonisolated enum GarmentIsolator {
    enum Kind: Sendable { case top, bottoms }

    struct Region: @unchecked Sendable {
        let kind: Kind
        /// Normalized to the analyzed photo, top-left origin.
        let bounds: CGRect
        /// The garment region with everything else transparent, cropped to `bounds`.
        let cutout: CGImage
        /// The photo cropped to `bounds`.
        let crop: CGImage
    }

    enum Problem: Sendable, Equatable {
        /// Vision couldn't run here. In the iOS simulator, body pose can't be set up at all.
        case analysisFailed
        case noPerson
        /// A person was found, but not enough of their body to place garments.
        case bodyNotFound
        case noUsableGarments
    }

    struct Output: @unchecked Sendable {
        var regions: [Region] = []
        /// The chosen person, normalized, top-left origin.
        var subject: CGRect?
        var problem: Problem?
        var peopleCount = 0
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    @concurrent
    static func isolate(_ image: CGImage) async -> Output {
        analyze(image)
    }

    private static func analyze(_ image: CGImage) -> Output {
        let people = VNGeneratePersonInstanceMaskRequest()
        let pose = VNDetectHumanBodyPoseRequest()
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .accurate
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do { try handler.perform([people, pose, segmentation]) } catch {
            Logger(subsystem: "app.fitmix", category: "GarmentIsolator").error("Vision failed: \(error.localizedDescription, privacy: .public)")
            return Output(problem: .analysisFailed)
        }

        guard let observation = people.results?.first, !observation.allInstances.isEmpty else {
            return Output(problem: .noPerson)
        }
        let labels = LabelMask(observation.instanceMask)
        guard let person = labels.largestInstance(in: observation.allInstances) else { return Output(problem: .noPerson) }
        var output = Output(peopleCount: observation.allInstances.count)

        // The pose whose joints fall on the chosen person.
        guard let joints = (pose.results ?? []).map({ Joints($0) })
            .max(by: { labels.hits($0, label: person) < labels.hits($1, label: person) }),
            labels.hits(joints, label: person) > 0,
            let hipY = joints.y([.leftHip, .rightHip]), let hipX = joints.x([.leftHip, .rightHip]) else {
            output.problem = .bodyNotFound
            return output
        }
        // Shoulders are needed for a top. Without them (photo cropped at the chest), only bottoms
        // can be placed, sized from the thigh instead of the torso.
        let shoulderY = joints.y([.leftShoulder, .rightShoulder]).flatMap { hipY - $0 > 0.03 ? $0 : nil }
        let kneeY = joints.y([.leftKnee, .rightKnee])
        guard let torso = shoulderY.map({ hipY - $0 }) ?? kneeY.flatMap({ $0 - hipY > 0.03 ? $0 - hipY : nil }) else {
            output.problem = .bodyNotFound
            return output
        }
        // A point inside the body, to pick the connected area that is this person.
        let torsoCentre: CGPoint = if let shoulderY {
            CGPoint(x: ((joints.x([.leftShoulder, .rightShoulder]) ?? hipX) + hipX) / 2, y: (shoulderY + hipY) / 2)
        } else {
            CGPoint(x: hipX, y: hipY + torso * 0.3)
        }

        // The person's pixels: fine segmentation where available, limited to this person's instance,
        // then only the part connected to the torso.
        var mask = PersonMask(labels: labels, person: person,
                              segmentation: segmentation.results?.first?.pixelBuffer)
        mask.keepComponent(around: torsoCentre)
        guard let personBox = mask.box(), mask.count > 0 else { return Output(problem: .noPerson) }
        output.subject = mask.normalized(personBox)

        let split = hipY
        let legEnd: Double = if let ankle = joints.y([.leftAnkle, .rightAnkle]) {
            ankle + torso * 0.02
        } else if let knee = kneeY {
            knee + (knee - hipY) * 0.9
        } else {
            1
        }
        // Keep hands and arms out of Bottoms: only the columns the legs occupy.
        let legXs = joints.xs([.leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle])
        let pad = torso * 0.28 * Double(image.height) / Double(image.width)
        let legColumns = ((legXs.min() ?? hipX) - pad)...((legXs.max() ?? hipX) + pad)

        let minPixels = max(40, mask.count / 16)
        var regions: [Region] = []
        if let shoulderY,
           // The collar sits a little above the shoulder joints.
           let top = mask.region(rows: (shoulderY - torso * 0.12)...split, columns: nil, minPixels: minPixels),
           let region = makeRegion(.top, top, mask: mask, image: image) {
            regions.append(region)
        }
        if legEnd > split + 0.02,
           let bottoms = mask.region(rows: split...legEnd, columns: legColumns, minPixels: minPixels),
           let region = makeRegion(.bottoms, bottoms, mask: mask, image: image) {
            regions.append(region)
        }
        output.regions = regions
        if regions.isEmpty { output.problem = .noUsableGarments }
        return output
    }

    /// Scales the region's mask up to the photo, cuts the garment out, and crops both to its box.
    private static func makeRegion(_ kind: Kind, _ region: PersonMask.RegionMask, mask: PersonMask, image: CGImage) -> Region? {
        let width = Double(image.width), height = Double(image.height)
        let n = mask.normalized(region.box)
        let pixelBox = CGRect(x: n.minX * width, y: n.minY * height, width: n.width * width, height: n.height * height)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixelBox.width >= 8, pixelBox.height >= 8, let maskImage = region.cgImage(),
              let crop = image.cropping(to: pixelBox) else { return nil }

        let photo = CIImage(cgImage: image)
        let scaledMask = CIImage(cgImage: maskImage)
            .transformed(by: CGAffineTransform(scaleX: width / Double(maskImage.width), y: height / Double(maskImage.height)))
        let cut = photo.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: photo.extent),
            kCIInputMaskImageKey: scaledMask,
        ])
        // Core Image's origin is bottom-left.
        let ciBox = CGRect(x: pixelBox.minX, y: height - pixelBox.maxY, width: pixelBox.width, height: pixelBox.height)
        guard let cutout = context.createCGImage(cut, from: ciBox, format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return Region(kind: kind, bounds: CGRect(x: pixelBox.minX / width, y: pixelBox.minY / height,
                                                 width: pixelBox.width / width, height: pixelBox.height / height),
                      cutout: cutout, crop: crop)
    }
}

// MARK: - Mask and joints helpers

/// Copy of Vision's instance-label mask (one byte per pixel, 0 = background, row 0 = top).
nonisolated private struct LabelMask {
    let width: Int
    let height: Int
    let labels: [UInt8]

    init(_ buffer: CVPixelBuffer) {
        (width, height, labels) = copyBytes(buffer)
    }

    func label(atNormalized x: Double, _ y: Double) -> UInt8 {
        let px = min(width - 1, max(0, Int(x * Double(width))))
        let py = min(height - 1, max(0, Int(y * Double(height))))
        return labels[py * width + px]
    }

    /// The instance with the most pixels.
    func largestInstance(in instances: IndexSet) -> UInt8? {
        var counts = [Int](repeating: 0, count: 256)
        for l in labels where l != 0 { counts[Int(l)] += 1 }
        guard let best = instances.filter({ $0 > 0 && $0 < 256 }).max(by: { counts[$0] < counts[$1] }),
              counts[best] > 0 else { return nil }
        return UInt8(best)
    }

    /// How many of the pose's joints sit on this person.
    func hits(_ joints: Joints, label: UInt8) -> Int {
        joints.points.values.filter { self.label(atNormalized: $0.x, $0.y) == label }.count
    }
}

/// One person's pixels (row 0 = top), at the finest resolution available.
nonisolated private struct PersonMask {
    let width: Int
    let height: Int
    private(set) var on: [Bool]
    private(set) var count: Int

    struct RegionMask {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        /// In mask pixels.
        let box: CGRect

        func cgImage() -> CGImage? {
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// Fine segmentation pixels that fall on `person`'s instance; the instance mask alone if
    /// segmentation isn't available.
    init(labels: LabelMask, person: UInt8, segmentation: CVPixelBuffer?) {
        if let segmentation {
            let (w, h, bytes) = copyBytes(segmentation)
            width = w; height = h
            var on = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                let ny = (Double(y) + 0.5) / Double(h)
                for x in 0..<w where bytes[y * w + x] > 127 {
                    if labels.label(atNormalized: (Double(x) + 0.5) / Double(w), ny) == person { on[y * w + x] = true }
                }
            }
            self.on = on
        } else {
            width = labels.width; height = labels.height
            on = labels.labels.map { $0 == person }
        }
        count = on.reduce(0) { $1 ? $0 + 1 : $0 }
    }

    func normalized(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX / Double(width), y: box.minY / Double(height),
               width: box.width / Double(width), height: box.height / Double(height))
    }

    /// Keeps only the connected area containing (or nearest to) `seed`, normalized top-left.
    mutating func keepComponent(around seed: CGPoint) {
        guard count > 0 else { return }
        let sx = min(width - 1, max(0, Int(seed.x * Double(width))))
        let sy = min(height - 1, max(0, Int(seed.y * Double(height))))
        // Nearest "on" pixel to the seed, searching outward in rings.
        var start: Int?
        search: for r in 0..<max(width, height) {
            for y in max(0, sy - r)...min(height - 1, sy + r) {
                for x in max(0, sx - r)...min(width - 1, sx + r) where on[y * width + x] {
                    start = y * width + x
                    break search
                }
            }
            if r > max(width, height) / 8 { break }
        }
        guard let start else { return }
        var keep = [Bool](repeating: false, count: on.count)
        var stack = [start]
        keep[start] = true
        var kept = 0
        while let i = stack.popLast() {
            kept += 1
            let x = i % width, y = i / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let j = ny * width + nx
                if on[j] && !keep[j] { keep[j] = true; stack.append(j) }
            }
        }
        on = keep
        count = kept
    }

    /// Bounding box in mask pixels.
    func box() -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where on[y * width + x] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The person's pixels inside a band of rows (and optionally columns), normalized ranges.
    func region(rows: ClosedRange<Double>, columns: ClosedRange<Double>?, minPixels: Int) -> RegionMask? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        var count = 0, minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        let y0 = max(0, Int(rows.lowerBound * Double(height))), y1 = min(height - 1, Int(rows.upperBound * Double(height)))
        let x0 = columns.map { max(0, Int($0.lowerBound * Double(width))) } ?? 0
        let x1 = columns.map { min(width - 1, Int($0.upperBound * Double(width))) } ?? width - 1
        guard y0 <= y1, x0 <= x1 else { return nil }
        for y in y0...y1 {
            for x in x0...x1 where on[y * width + x] {
                bytes[y * width + x] = 255
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard count >= minPixels, maxX - minX >= 3, maxY - minY >= 3 else { return nil }
        return RegionMask(width: width, height: height, bytes: bytes,
                          box: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}

/// A one-byte-per-pixel buffer as a tightly packed array.
nonisolated private func copyBytes(_ buffer: CVPixelBuffer) -> (Int, Int, [UInt8]) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    var bytes = [UInt8](repeating: 0, count: width * height)
    if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
        for y in 0..<height {
            for x in 0..<width { bytes[y * width + x] = base[y * stride + x] }
        }
    }
    return (width, height, bytes)
}

/// Confident body-pose joints, normalized with a top-left origin.
nonisolated private struct Joints {
    let points: [VNHumanBodyPoseObservation.JointName: CGPoint]

    init(_ observation: VNHumanBodyPoseObservation) {
        let recognized = (try? observation.recognizedPoints(.all)) ?? [:]
        points = recognized.compactMapValues { $0.confidence > 0.3 ? CGPoint(x: $0.location.x, y: 1 - $0.location.y) : nil }
    }

    func y(_ names: [VNHumanBodyPoseObservation.JointName]) -> Double? {
        let ys = names.compactMap { points[$0].map { Double($0.y) } }
        return ys.isEmpty ? nil : ys.reduce(0, +) / Double(ys.count)
    }

    func x(_ names: [VNHumanBodyPoseObservation.JointName]) -> Double? {
        let xs = xs(names)
        return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    func xs(_ names: [VNHumanBodyPoseObservation.JointName]) -> [Double] {
        names.compactMap { points[$0].map { Double($0.x) } }
    }
}
