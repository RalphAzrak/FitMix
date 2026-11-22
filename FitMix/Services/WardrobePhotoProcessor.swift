import CoreImage
import UIKit
import Vision

nonisolated enum WardrobePhotoProcessor {
    struct Preview: Sendable {
        let original: UIImage
        let cleaned: UIImage?
    }

    private static let context = CIContext()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    @concurrent
    static func prepare(_ image: UIImage, category: WardrobeCategory) async -> Preview {
        let original = image.normalized(maxDimension: 2048)
        return Preview(original: original, cleaned: clean(original, category: category))
    }

    @concurrent
    static func files(from preview: Preview, preferCleaned: Bool) async throws -> WardrobePhotoFiles {
        let selected = (preferCleaned ? preview.cleaned : nil) ?? preview.original
        guard let original = preview.original.jpegData(compressionQuality: 0.88),
              let thumbnail = selected.normalized(maxDimension: 360).jpegData(compressionQuality: 0.82) else {
            throw WardrobeError.invalidPhoto
        }
        let cleaned = preview.cleaned?.jpegData(compressionQuality: 0.9)
        return WardrobePhotoFiles(original: original, cleaned: cleaned, thumbnail: thumbnail,
                                  prefersCleaned: preferCleaned && cleaned != nil)
    }

    private static func clean(_ image: UIImage, category: WardrobeCategory) -> UIImage? {
        guard !Task.isCancelled, let source = image.cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: source, orientation: .up)
        do {
            try handler.perform([request])
            guard !Task.isCancelled, let observation = request.results?.first else { return nil }
            let labels = LabelMask(observation.instanceMask)
            guard let subject = subject(in: labels, instances: observation.allInstances, category: category) else { return nil }
            let mask = try observation.generateScaledMaskForImage(forInstances: subject.instances, from: handler)
            guard !Task.isCancelled else { return nil }
            return composite(source, mask: CIImage(cvPixelBuffer: mask), normalizedBounds: subject.bounds)
        } catch {
            return nil
        }
    }

    private struct Region {
        var count = 0
        var bounds = CGRect.null

        mutating func add(x: Int, y: Int) {
            count += 1
            bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }

    private static func subject(in mask: LabelMask, instances: IndexSet,
                                category: WardrobeCategory) -> (instances: IndexSet, bounds: CGRect)? {
        guard mask.width > 0, mask.height > 0 else { return nil }
        var regions = [Region](repeating: Region(), count: 256)
        for (offset, label) in mask.labels.enumerated() where label != 0 {
            regions[Int(label)].add(x: offset % mask.width, y: offset / mask.width)
        }
        let ranked = instances.filter { (1..<regions.count).contains($0) && regions[$0].count > 0 }
            .sorted { regions[$0].count > regions[$1].count }
        guard let primary = ranked.first else { return nil }
        let main = regions[primary]
        let coverage = Double(main.count) / Double(mask.width * mask.height)
        guard (0.006...0.94).contains(coverage) else { return nil }
        var chosen = IndexSet(integer: primary)
        var bounds = main.bounds
        if category == .shoes {
            let candidates = ranked.dropFirst().filter { regions[$0].count * 4 >= main.count }
            if let second = candidates.first(where: { index in
                if candidates.count == 1 { return true }
                let other = regions[index].bounds
                let gapX = max(0, main.bounds.minX - other.maxX, other.minX - main.bounds.maxX)
                let gapY = max(0, main.bounds.minY - other.maxY, other.minY - main.bounds.maxY)
                return hypot(gapX, gapY) <= max(main.bounds.width, main.bounds.height)
            }) {
                chosen.insert(second)
                bounds = bounds.union(regions[second].bounds)
            }
        }
        // Vision's label rows start at the top, while Core Image's coordinates start at the bottom.
        return (chosen, CGRect(x: bounds.minX / CGFloat(mask.width),
                               y: 1 - bounds.maxY / CGFloat(mask.height),
                               width: bounds.width / CGFloat(mask.width), height: bounds.height / CGFloat(mask.height)))
    }

    private static func composite(_ source: CGImage, mask: CIImage, normalizedBounds: CGRect) -> UIImage? {
        let input = CIImage(cgImage: source)
        let extent = input.extent
        let subject = CGRect(x: normalizedBounds.minX * extent.width, y: normalizedBounds.minY * extent.height,
                             width: normalizedBounds.width * extent.width, height: normalizedBounds.height * extent.height)
        let padding = max(subject.width, subject.height) * 0.12
        let frame = subject.insetBy(dx: -padding, dy: -padding).integral
        let offset = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
        let output = CGRect(origin: .zero, size: frame.size)

        // Keep garment highlights a little below the white canvas so white fabrics still have edges.
        let corrected = input
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.08])
            .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 0.86])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.22])
        let alignedMask = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                                                 y: extent.height / mask.extent.height))
            .transformed(by: offset)
        let white = CIImage(color: .white).cropped(to: output)
        let result = corrected.transformed(by: offset).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: white, kCIInputMaskImageKey: alignedMask
        ])
        guard let rendered = context.createCGImage(result, from: output, format: .RGBA8, colorSpace: colorSpace) else { return nil }
        return UIImage(cgImage: rendered).normalized(maxDimension: 1600)
    }
}
