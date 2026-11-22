import CoreGraphics
import CoreVideo
import Foundation
import UIKit
import Vision

/// Checks on-device that a photo shows a whole person, head to feet.
nonisolated enum BodyPhotoAnalyzer {
    /// Returns `nil` when the check itself could not run (for example, Vision is unavailable).
    @concurrent
    static func analyze(image cgImage: CGImage) async -> BodyPhotoAnalysis? {
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
        return BodyPhotoAnalysis(personDetected: true, fullBodyVisible: fullBody)
    }
}

/// Checks, on-device, whether a selfie shows a face. `nil` means the check could not run.
nonisolated enum SelfieCheck {
    @concurrent
    static func hasFace(_ image: CGImage) async -> Bool? {
        let request = VNDetectFaceRectanglesRequest()
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return nil }
        return !(request.results ?? []).isEmpty
    }
}

extension UIImage {
    /// `normalized`, done on a background thread: a 12-megapixel camera photo takes long enough to redraw
    /// that doing it on the main thread makes the screen stutter.
    @concurrent
    nonisolated func normalizedInBackground(maxDimension: CGFloat = 2048) async -> UIImage {
        normalized(maxDimension: maxDimension)
    }

    /// A JPEG of the picture, upright and no larger than `maxDimension`, for sending to the avatar service.
    /// Redrawing the picture also leaves out everything the camera attached to it, such as where it was taken.
    @concurrent
    nonisolated func uploadJPEG(maxDimension: CGFloat = 1536, quality: CGFloat = 0.85) async -> Data? {
        normalized(maxDimension: maxDimension).jpegData(compressionQuality: quality)
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
