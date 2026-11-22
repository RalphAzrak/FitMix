import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

nonisolated enum WardrobePhotoProcessor {
    struct Preview: Sendable {
        let original: UIImage
        let cleaned: UIImage?
    }

    private static let context = CIContext()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let canvas = CGRect(x: 0, y: 0, width: 1280, height: 1600)

    static let fullPhoto = CGRect(x: 0, y: 0, width: 1, height: 1)

    @concurrent
    static func prepare(_ image: UIImage, category: WardrobeCategory, crop: CGRect = fullPhoto) async -> Preview {
        let original = image.normalized(maxDimension: 2048)
        return Preview(original: original, cleaned: cropped(original, to: crop).flatMap { clean($0, category: category) })
    }

    @concurrent
    static func catalogJPEG(_ image: UIImage, crop: CGRect) async -> Data? {
        if crop == fullPhoto {
            return image.normalized(maxDimension: 1024).jpegData(compressionQuality: 0.82)
        }
        return cropped(image.normalized(maxDimension: 2048), to: crop)?
            .normalized(maxDimension: 1024).jpegData(compressionQuality: 0.82)
    }

    private static func cropped(_ image: UIImage, to crop: CGRect) -> UIImage? {
        guard crop != fullPhoto else { return image }
        guard let source = image.cgImage else { return nil }
        let width = CGFloat(source.width), height = CGFloat(source.height)
        let pixels = CGRect(x: crop.minX * width, y: crop.minY * height, width: crop.width * width,
                            height: crop.height * height).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixels.width >= 1, pixels.height >= 1, let selection = source.cropping(to: pixels) else { return nil }
        return UIImage(cgImage: selection)
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
        guard subject.width > 0, subject.height > 0, mask.extent.width > 0, mask.extent.height > 0 else { return nil }

        // Fit the full silhouette onto a consistent product-photo canvas, with a little more space above it.
        let scale = min(canvas.width * 0.82 / subject.width, canvas.height * 0.76 / subject.height)
        let placement = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                         tx: canvas.midX - subject.midX * scale,
                                         ty: canvas.height * 0.47 - subject.midY * scale)
        let matte = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                                           y: extent.height / mask.extent.height))
            .transformed(by: placement)
            .cropped(to: canvas)

        let garment = input
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.08])
            .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 0.92,
                                                                  "inputShadowAmount": 0.06])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.24])
            .transformed(by: placement)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = garment
        blend.backgroundImage = studioBackdrop(shapedBy: matte)
        blend.maskImage = matte
        guard let result = blend.outputImage,
              let rendered = context.createCGImage(result, from: canvas, format: .RGBA8, colorSpace: colorSpace) else {
            return nil
        }
        return UIImage(cgImage: rendered)
    }

    private static func studioBackdrop(shapedBy matte: CIImage) -> CIImage {
        let light = CIColor(red: 0.91, green: 0.91, blue: 0.90)
        let gradient = CIFilter.radialGradient()
        gradient.center = CGPoint(x: canvas.width * 0.72, y: canvas.height * 0.86)
        gradient.radius0 = 60
        gradient.radius1 = 1660
        gradient.color0 = light
        gradient.color1 = CIColor(red: 0.84, green: 0.84, blue: 0.83)
        let background = (gradient.outputImage ?? CIImage(color: light)).cropped(to: canvas)

        // Cast a diffuse shadow down and to the left, using the actual garment silhouette.
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = matte.transformed(by: CGAffineTransform(translationX: -30, y: -36))
        blur.radius = 23

        let shadow = CIFilter.blendWithMask()
        shadow.inputImage = CIImage(color: CIColor(red: 0.22, green: 0.21, blue: 0.20, alpha: 0.26)).cropped(to: canvas)
        shadow.backgroundImage = background
        shadow.maskImage = blur.outputImage?.cropped(to: canvas)
        return shadow.outputImage ?? background
    }
}
