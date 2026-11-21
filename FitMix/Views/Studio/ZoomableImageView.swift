import SwiftUI
import UIKit
import AVFoundation

/// Full-screen viewer for the street capture: pinch or double-tap to zoom, drag to pan.
/// Opens zoomed onto the selected garment when the scan has its region.
struct ZoomableImageView: View {
    var image: UIImage
    /// Normalized region to start zoomed in on.
    var focus: CGRect?
    var focusLabel: String?
    /// What the picture is, for VoiceOver.
    var label = "Street capture"
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseScale: CGFloat = 1
    @State private var baseOffset: CGSize = .zero
    @State private var didFocus = false

    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let fitted = AVMakeRect(aspectRatio: image.size, insideRect: CGRect(origin: .zero, size: proxy.size))
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: fitted.width, height: fitted.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .gesture(pinch(fitted: fitted.size).simultaneously(with: pan(fitted: fitted.size)))
                    .onTapGesture(count: 2) { toggleZoom(fitted: fitted.size) }
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityHint("Pinch or double-tap to zoom")
            }
            .onAppear {
                guard !didFocus, let focus else { return }
                didFocus = true
                zoom(to: focus, fitted: fitted.size)
            }
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.5), in: Circle())
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            .padding(12)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                if let focusLabel { Text(focusLabel).font(.system(size: 13, weight: .semibold)) }
                Text(scale > 1.01 ? String(format: "%.1f×", scale) : "Pinch to zoom")
                    .font(.system(size: 13))
                    .opacity(0.8)
                if scale > 1.01 {
                    Button("Reset") { withAnimation(.snappy) { reset() } }
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.bottom, 16)
        }
        .statusBarHidden()
    }

    private func pinch(fitted: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(baseScale * value.magnification, 1), maxScale)
                offset = clamped(offset, scale: scale, fitted: fitted)
            }
            .onEnded { _ in
                baseScale = scale
                baseOffset = offset
            }
    }

    private func pan(fitted: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = clamped(CGSize(width: baseOffset.width + value.translation.width,
                                        height: baseOffset.height + value.translation.height),
                                 scale: scale, fitted: fitted)
            }
            .onEnded { _ in baseOffset = offset }
    }

    private func toggleZoom(fitted: CGSize) {
        withAnimation(.snappy) {
            if scale > 1.01 { reset() } else if let focus { zoom(to: focus, fitted: fitted) } else {
                scale = 2.5; baseScale = 2.5
            }
        }
    }

    private func zoom(to region: CGRect, fitted: CGSize) {
        let target = min(maxScale, max(1.5, 0.8 / max(region.width, region.height)))
        scale = target
        baseScale = target
        // Move the region's center to the middle of the screen.
        let dx = (0.5 - region.midX) * fitted.width * target
        let dy = (0.5 - region.midY) * fitted.height * target
        offset = clamped(CGSize(width: dx, height: dy), scale: target, fitted: fitted)
        baseOffset = offset
    }

    private func reset() {
        scale = 1; baseScale = 1; offset = .zero; baseOffset = .zero
    }

    private func clamped(_ proposed: CGSize, scale: CGFloat, fitted: CGSize) -> CGSize {
        let maxX = max(0, (fitted.width * scale - fitted.width) / 2)
        let maxY = max(0, (fitted.height * scale - fitted.height) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX), height: min(max(proposed.height, -maxY), maxY))
    }
}
