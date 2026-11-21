import SwiftUI
import UIKit
import CoreImage

/// Plain tile with the garment centered on it. The tile shade is picked from the garment's own
/// brightness so light pieces sit on a darker tile and dark pieces on a lighter one.
struct GarmentTile: View {
    enum Source {
        case image(UIImage)
        case remote(URL)
        case none
    }

    var source: Source
    var category: GarmentCategory
    var cornerRadius: CGFloat = 10

    @State private var luminance: Double?

    var body: some View {
        ZStack {
            Rectangle().fill(tileColor)
            switch source {
            case .image(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            case .remote(let url):
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit().padding(8)
                    case .failure: fallback(text: "Image unavailable")
                    default: ProgressView()
                    }
                }
            case .none:
                fallback(text: "No image")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: imageID) {
            if case .image(let image) = source { luminance = await GarmentTone.luminance(of: image) }
        }
    }

    private var imageID: ObjectIdentifier? {
        if case .image(let image) = source { return ObjectIdentifier(image) }
        return nil
    }

    private var tileColor: Color {
        guard let luminance else { return Color(red: 0.929, green: 0.918, blue: 0.898) }
        if luminance > 0.7 { return Color(red: 0.80, green: 0.78, blue: 0.75) }   // light garment → darker tile
        if luminance < 0.35 { return Color(red: 0.961, green: 0.953, blue: 0.937) } // dark garment → light tile
        return Color(red: 0.918, green: 0.906, blue: 0.886)
    }

    private func fallback(text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: category.symbol).font(.system(size: 22)).foregroundStyle(AuthPalette.secondary)
            Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(AuthPalette.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

enum GarmentTone {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// Average brightness of the visible (non-transparent) pixels, 0…1.
    nonisolated static func luminance(of image: UIImage) async -> Double? {
        await Task.detached(priority: .utility) { () -> Double? in
            guard let cg = image.cgImage else { return nil }
            let input = CIImage(cgImage: cg)
            guard let filter = CIFilter(name: "CIAreaAverage",
                                        parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]),
                  let output = filter.outputImage else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: nil)
            let alpha = Double(pixel[3]) / 255
            guard alpha > 0.02 else { return nil }
            // The average is premultiplied, so divide by coverage to get the garment's own color.
            let r = Double(pixel[0]) / 255 / alpha, g = Double(pixel[1]) / 255 / alpha, b = Double(pixel[2]) / 255 / alpha
            return min(1, 0.2126 * r + 0.7152 * g + 0.0722 * b)
        }.value
    }
}

extension WorkingLook.Piece {
    /// Best image for this piece's card: the replacement's product image, else the cutout, else the crop.
    var tileSource: GarmentTile.Source {
        if let replacement { return replacement.image.tileSource }
        if let cutout = detected.cutout { return .image(cutout) }
        if let crop = detected.crop { return .image(crop) }
        return .none
    }
}

extension Optional where Wrapped == ProductImage {
    var tileSource: GarmentTile.Source {
        switch self {
        case .local(let image): .image(image)
        case .remote(let url): .remote(url)
        case nil: .none
        }
    }
}
