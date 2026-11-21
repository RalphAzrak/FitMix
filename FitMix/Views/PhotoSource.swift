import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

enum CameraAccess {
    enum Problem: Identifiable {
        case unavailable, denied
        var id: Self { self }
    }

    /// Asks for camera permission if needed. Returns `nil` when the camera can be used.
    static func check() async -> Problem? {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return nil
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? nil : .denied
        default: return .denied
        }
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// The system camera, with its own retake / use-photo review.
struct CameraPicker: UIViewControllerRepresentable {
    var device: UIImagePickerController.CameraDevice
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        if UIImagePickerController.isCameraDeviceAvailable(device) { picker.cameraDevice = device }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Where a photo should come from.
enum PhotoSourceKind: Hashable, Identifiable {
    case camera, library
    var id: Self { self }
}

/// Offers "Take Photo" or "Choose from Photos" in a dialog, then runs the chosen picker.
struct PhotoSourceModifier: ViewModifier {
    @Binding var isPresented: Bool
    var title: String
    var camera: UIImagePickerController.CameraDevice
    var onImage: (UIImage) -> Void
    @State private var request: PhotoSourceKind?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: $isPresented, titleVisibility: .visible) {
                Button("Take Photo") { request = .camera }
                Button("Choose from Photos") { request = .library }
                Button("Cancel", role: .cancel) {}
            }
            .photoPicker(request: $request, camera: camera, onImage: onImage)
    }
}

/// Runs the camera or the photo library when `request` is set, and explains what to do when the
/// camera can't be used. Cancelling either picker calls nothing.
struct PhotoPickerModifier: ViewModifier {
    @Binding var request: PhotoSourceKind?
    var camera: UIImagePickerController.CameraDevice
    var onImage: (UIImage) -> Void

    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var cameraProblem: CameraAccess.Problem?
    @State private var loadFailed = false

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, kind in
                guard let kind else { return }
                request = nil
                switch kind {
                case .camera:
                    Task {
                        if let problem = await CameraAccess.check() { cameraProblem = problem } else { showCamera = true }
                    }
                case .library:
                    showLibrary = true
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(device: camera, onImage: onImage).ignoresSafeArea()
            }
            .photosPicker(isPresented: $showLibrary, selection: $libraryItem, matching: .images)
            .onChange(of: libraryItem) { _, item in
                guard let item else { return }
                libraryItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        onImage(image)
                    } else {
                        loadFailed = true
                    }
                }
            }
            .alert(item: $cameraProblem) { problem in
                switch problem {
                case .denied:
                    Alert(title: Text("Camera access is off"),
                          message: Text("Turn on Camera for FitMix in Settings, or choose a photo from your library instead."),
                          primaryButton: .default(Text("Open Settings")) { CameraAccess.openSettings() },
                          secondaryButton: .default(Text("Choose from Photos")) { showLibrary = true })
                case .unavailable:
                    Alert(title: Text("No camera available"),
                          message: Text("This device can't take photos here. Choose one from your library instead."),
                          primaryButton: .default(Text("Choose from Photos")) { showLibrary = true },
                          secondaryButton: .cancel())
                }
            }
            .alert("That photo couldn't be opened", isPresented: $loadFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Try a different photo.")
            }
    }
}

extension View {
    func photoSource(isPresented: Binding<Bool>, title: String, camera: UIImagePickerController.CameraDevice,
                     onImage: @escaping (UIImage) -> Void) -> some View {
        modifier(PhotoSourceModifier(isPresented: isPresented, title: title, camera: camera, onImage: onImage))
    }

    /// Opens the camera or the library directly, without the choice dialog.
    func photoPicker(request: Binding<PhotoSourceKind?>, camera: UIImagePickerController.CameraDevice,
                     onImage: @escaping (UIImage) -> Void) -> some View {
        modifier(PhotoPickerModifier(request: request, camera: camera, onImage: onImage))
    }
}
