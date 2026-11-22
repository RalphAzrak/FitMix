import SwiftUI

struct WardrobeCropView: View {
    let image: UIImage
    let initialCrop: CGRect
    var hint = "Drag the frame or its lower-right corner to include the whole garment."
    var minimumFraction: CGFloat = 0.18
    var allowedBounds = WardrobePhotoProcessor.fullPhoto
    var resetBounds = WardrobePhotoProcessor.fullPhoto
    let confirm: (CGRect) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var crop = WardrobePhotoProcessor.fullPhoto
    @State private var dragStart: CGRect?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(Color.fmSecondary)
                GeometryReader { viewport in
                    let scale = min(viewport.size.width / max(image.size.width, 1),
                                    viewport.size.height / max(image.size.height, 1))
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    cropCanvas(size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Button("Reset Crop") { crop = resetBounds }
                    .frame(minHeight: 44)
            }
            .padding(20)
            .background(Color.wardrobeBackground)
            .navigationTitle("Adjust Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Crop") {
                        confirm(crop)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { crop = initialCrop }
    }

    private func cropCanvas(_ size: CGSize) -> some View {
        let box = CGRect(x: crop.minX * size.width, y: crop.minY * size.height, width: crop.width * size.width,
                         height: crop.height * size.height)
        return ZStack(alignment: .topLeading) {
            Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
            Rectangle().fill(.white.opacity(0.01))
                .overlay(Rectangle().strokeBorder(Color.fmCobalt, lineWidth: 3))
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
                .gesture(changeCrop(size, resize: false))
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.fmCobalt, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .position(x: box.maxX - 12, y: box.maxY - 12)
                .gesture(changeCrop(size, resize: true))
                .accessibilityLabel("Crop size")
                .accessibilityIdentifier("crop-resize-handle")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: resizeCrop(from: crop, dx: 0.04, dy: 0.04)
                    case .decrement: resizeCrop(from: crop, dx: -0.04, dy: -0.04)
                    @unknown default: break
                    }
                }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "wardrobe-crop")
        .accessibilityLabel("Garment crop")
    }

    private func changeCrop(_ size: CGSize, resize: Bool) -> some Gesture {
        DragGesture(coordinateSpace: .named("wardrobe-crop"))
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                if dragStart == nil { dragStart = crop }
                guard let start = dragStart else { return }
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                if resize {
                    resizeCrop(from: start, dx: dx, dy: dy)
                } else {
                    crop.origin.x = min(allowedBounds.maxX - start.width, max(allowedBounds.minX, start.minX + dx))
                    crop.origin.y = min(allowedBounds.maxY - start.height, max(allowedBounds.minY, start.minY + dy))
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeCrop(from start: CGRect, dx: CGFloat, dy: CGFloat) {
        crop.size.width = min(allowedBounds.maxX - start.minX, max(minimumFraction, start.width + dx))
        crop.size.height = min(allowedBounds.maxY - start.minY, max(minimumFraction, start.height + dy))
    }
}
