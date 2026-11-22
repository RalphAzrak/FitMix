import CoreVideo

/// Copy of Vision's instance-label mask (one byte per pixel, 0 = background, row 0 = top).
nonisolated struct LabelMask {
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
