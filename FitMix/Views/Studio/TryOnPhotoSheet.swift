import SwiftUI
import UIKit

/// Asks for a full-body photo of the user, for try-on. Reuses the avatar's photo picker, the
/// on-device full-body check, and storage, so the user keeps one full-body photo on this iPhone.
struct TryOnPhotoSheet: View {
    /// Called with the saved photo; the caller continues with the same selected outfit.
    var onUse: (UIImage) -> Void
    @Environment(AvatarStore.self) private var avatar
    @Environment(\.dismiss) private var dismiss
    @State private var showPhotoSource = false
    @State private var candidate: UIImage?
    @State private var analysis: BodyPhotoAnalysis??   // outer nil: still checking

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Take a full-body photo of yourself")
                        .font(.system(size: 26, weight: .medium, design: .serif))
                        .foregroundStyle(AuthPalette.onSurface)
                    Text("Try-on starts from this photo. Pieces you didn't choose stay as you're wearing them here. It's saved only on this iPhone and is also your avatar's full-body photo.")
                        .font(.system(size: 14))
                        .foregroundStyle(AuthPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let candidate {
                        PhotoPreview(image: candidate, label: "Your full-body photo", notice: analysis.map { $0.notice })
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            tip("figure.stand", "Stand upright facing the camera, arms slightly away from your body.")
                            tip("arrow.up.and.down", "Fit your whole body in the frame, head to feet.")
                            tip("timer", "Prop the phone up and use a timer, or ask someone to take it.")
                            tip("sun.max", "Use even light and a plain background.")
                        }
                        .padding(14)
                        .background(AuthPalette.containerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(16)
            }
            .background(AuthPalette.surface)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if let candidate {
                        Button("Use This Photo") {
                            guard let analysis else { return }
                            avatar.saveBodyPhoto(candidate, analysis: analysis)
                            onUse(avatar.bodyPhoto ?? candidate)
                            dismiss()
                        }
                        .buttonStyle(AuthPrimaryButtonStyle())
                        .disabled(analysis == nil)
                        .opacity(analysis == nil ? 0.5 : 1)
                        Button("Retake") { showPhotoSource = true }
                            .buttonStyle(AuthSocialButtonStyle(background: AuthPalette.container, foreground: AuthPalette.onSurface))
                    } else {
                        Button { showPhotoSource = true } label: { Label("Take Photo", systemImage: "camera") }
                            .buttonStyle(AuthPrimaryButtonStyle())
                    }
                }
                .padding(16)
                .background(AuthPalette.surface)
            }
            .navigationTitle("Your try-on photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.light)
        .photoSource(isPresented: $showPhotoSource, title: "Full-body photo", camera: .front) { image in
            let normalized = image.normalized()
            candidate = normalized
            analysis = nil
            Task {
                let result: BodyPhotoAnalysis? = if let cg = normalized.cgImage { await BodyPhotoAnalyzer.analyze(image: cg) } else { nil }
                if candidate === normalized { analysis = .some(result) }
            }
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(AuthPalette.primary).frame(width: 22)
            Text(text).font(.system(size: 14)).foregroundStyle(AuthPalette.onSurface)
        }
    }
}
