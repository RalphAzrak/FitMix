import CoreGraphics
import CoreVideo
import Foundation
import UIKit
import Vision

/// Checks a full-body photo on-device and measures the body outline.
nonisolated enum BodyPhotoAnalyzer {
    /// Returns `nil` when the check itself could not run (for example, Vision is unavailable).
    @concurrent
    static func analyze(fileURL: URL) async -> BodyPhotoAnalysis? {
        guard let cgImage = UIImage(contentsOfFile: fileURL.path)?.cgImage else { return nil }
        return analyze(cgImage)
    }

    @concurrent
    static func analyze(image: CGImage) async -> BodyPhotoAnalysis? {
        analyze(image)
    }

    private static func analyze(_ cgImage: CGImage) -> BodyPhotoAnalysis? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        guard w > 8, h > 8 else { return nil }

        func on(_ x: Int, _ y: Int) -> Bool { pixels[y * stride + x] > 127 }

        var rowCounts = [Int](repeating: 0, count: h)
        var area = 0
        for y in 0..<h {
            var c = 0
            for x in 0..<w where on(x, y) { c += 1 }
            rowCounts[y] = c
            area += c
        }
        let minRow = max(2, w / 200)
        guard let top = rowCounts.firstIndex(where: { $0 >= minRow }),
              let bottom = rowCounts.lastIndex(where: { $0 >= minRow }), bottom > top else {
            return BodyPhotoAnalysis(personDetected: false, fullBodyVisible: false)
        }
        let bodyRows = bottom - top + 1
        let personDetected = Double(area) > 0.02 * Double(w * h) && Double(bodyRows) > 0.3 * Double(h)
        guard personDetected else { return BodyPhotoAnalysis(personDetected: false, fullBodyVisible: false) }

        // The mask can have a different aspect ratio than the photo, so convert to photo pixels.
        let sx = Double(cgImage.width) / Double(w)
        let sy = Double(cgImage.height) / Double(h)
        let bodyHeight = Double(bodyRows) * sy
        let widest = Double(rowCounts[top...bottom].max() ?? 0) * sx
        let margin = max(1, Int(Double(h) * 0.012))
        let fullBody = top >= margin && bottom <= h - 1 - margin && widest > 0 && bodyHeight / widest > 1.8

        // Horizontal centre of the torso.
        var sumX = 0.0, count = 0.0
        for y in (top + bodyRows / 5)...(top + bodyRows / 2) {
            for x in 0..<w where on(x, y) { sumX += Double(x); count += 1 }
        }
        guard count > 0 else { return BodyPhotoAnalysis(personDetected: true, fullBodyVisible: fullBody) }
        let centre = Int((sumX / count).rounded())

        /// Width of the outline through the body's centre line, at a fraction of the height measured from the top.
        func ratio(at t: Double) -> Double? {
            var runs: [Int] = []
            let mid = top + Int(Double(bodyRows) * t)
            for y in (mid - 2)...(mid + 2) where y >= 0 && y < h {
                guard on(centre, y) else { continue }
                var l = centre, r = centre
                while l > 0, on(l - 1, y) { l -= 1 }
                while r < w - 1, on(r + 1, y) { r += 1 }
                runs.append(r - l + 1)
            }
            guard !runs.isEmpty else { return nil }
            runs.sort()
            return Double(runs[runs.count / 2]) * sx / bodyHeight
        }

        return BodyPhotoAnalysis(personDetected: true, fullBodyVisible: fullBody,
                                 shoulderRatio: ratio(at: 0.19), chestRatio: ratio(at: 0.27),
                                 waistRatio: ratio(at: 0.385), hipRatio: ratio(at: 0.48))
    }
}

/// Finds and crops the face in a front-facing photo for the photo-based fallback.
nonisolated enum FacePhotoProcessor {
    enum Result: @unchecked Sendable {
        case face(CGImage)
        case noFaceFound
    }

    /// Width-to-height ratio of the crop; matches the face patch on the avatar's head.
    static let cropAspect = 0.70

    @concurrent
    static func cropFace(in image: CGImage) async -> Result {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let W = Double(image.width), H = Double(image.height)
        var cropRect: CGRect
        do {
            try handler.perform([request])
            guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
                return .noFaceFound
            }
            let box = face.boundingBox
            let faceW = box.width * W, faceH = box.height * H
            let cx = box.midX * W
            let cy = (1 - box.midY) * H - faceH * 0.06
            let cropW = faceW * 1.08
            let cropH = cropW / cropAspect
            cropRect = CGRect(x: cx - cropW / 2, y: cy - cropH / 2, width: cropW, height: cropH)
        } catch {
            // Face detection could not run here; fall back to the middle of the photo.
            let cropH = min(H, W / cropAspect) * 0.7
            let cropW = cropH * cropAspect
            cropRect = CGRect(x: (W - cropW) / 2, y: (H - cropH) / 2, width: cropW, height: cropH)
        }
        cropRect = cropRect.intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
        guard cropRect.width > 16, cropRect.height > 16, let crop = image.cropping(to: cropRect) else {
            return .noFaceFound
        }
        return .face(crop)
    }
}

extension UIImage {
    /// `normalized`, done on a background thread: a 12-megapixel camera photo takes long enough to redraw
    /// that doing it on the main thread makes the screen stutter.
    @concurrent
    nonisolated func normalizedInBackground(maxDimension: CGFloat = 2048) async -> UIImage {
        normalized(maxDimension: maxDimension)
    }

    /// Redraws the image upright, capped at `maxDimension`, so `cgImage` matches what the user sees.
    nonisolated func normalized(maxDimension: CGFloat = 2048) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return self }
        let scale = min(1, maxDimension / longest)
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

extension CGImage {
    /// Average colour of the middle of the image, used to tint the head to match the face.
    nonisolated func averageCentreColor() -> UIColor? {
        let region = CGRect(x: Double(width) * 0.3, y: Double(height) * 0.3,
                            width: Double(width) * 0.4, height: Double(height) * 0.4).integral
        guard let centre = cropping(to: region) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(centre, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}
