import UIKit

// MARK: - Capture → OutfitScan seam
//
// The Camera screen only produces a confirmed still. Turning that still into an `OutfitScan`
// happens here: `GarmentIsolator` analyzes the photo on-device, and this file turns its regions
// into `DetectedGarment`s. Camera and Studio don't know how garments are found.
// See Docs/CameraHandoff.md.

/// One still the user captured, reviewed, and confirmed with Use Photo.
struct ConfirmedCapture {
    /// Upright (orientation already applied), exactly as shown in review.
    let image: UIImage
    let capturedAt: Date
}

/// The scan for a capture, plus what to tell the user about it.
struct CaptureAnalysis {
    let scan: OutfitScan
    /// Why no garments (or fewer than expected) were found, in words. Nil when all is well.
    let problem: String?
    /// True when retaking is the way forward (nothing usable was found).
    let suggestsRetake: Bool
    /// Extra context that isn't a failure, e.g. several people in the photo.
    let note: String?
}

enum CaptureHandoff {
    /// The photo alone, before analysis. Outfit Review shows it while garments are being found.
    static func scan(for capture: ConfirmedCapture) -> OutfitScan {
        OutfitScan(capturedAt: capture.capturedAt, image: capture.image, subjectBounds: nil, garments: [])
    }

    /// Finds garments on the main person in the photo, on-device and off the main thread.
    static func analyze(_ capture: ConfirmedCapture) async -> CaptureAnalysis {
        guard let cgImage = capture.image.cgImage else {
            return CaptureAnalysis(scan: scan(for: capture), problem: "This photo couldn't be read.", suggestsRetake: true, note: nil)
        }
        let output = await GarmentIsolator.isolate(cgImage)
        let scale = capture.image.scale
        // HANDOFF: product matching would fill `label` and `matches` here.
        let garments = output.regions.map { region in
            DetectedGarment(category: region.kind == .top ? .top : .bottoms,
                            bounds: region.bounds,
                            cutout: UIImage(cgImage: region.cutout, scale: scale, orientation: .up),
                            crop: UIImage(cgImage: region.crop, scale: scale, orientation: .up))
        }
        let scan = OutfitScan(capturedAt: capture.capturedAt, image: capture.image,
                              subjectBounds: output.subject, garments: garments)

        let problem: String? = switch output.problem {
        case .analysisFailed: "Garment analysis couldn't run on this device. It needs an iPhone; the simulator can't run it."
        case .noPerson: "No person was found in this photo. Retake it with one person clearly in the frame."
        case .bodyNotFound: "A person was found, but not their shoulders and hips, so their clothes couldn't be separated. Retake with the person facing the camera, from the head down to at least the knees."
        case .noUsableGarments: "The person's clothes couldn't be separated in this photo. Retake it with their whole outfit in the frame and good light."
        case nil:
            garments.contains(where: { $0.category == .bottoms }) ? nil
                : "Only a top was found. To get bottoms too, include the person's legs in the frame."
        }
        let note = output.peopleCount > 1 ? "There's more than one person in this photo. FitMix used the largest one." : nil
        return CaptureAnalysis(scan: scan, problem: problem, suggestsRetake: garments.isEmpty, note: note)
    }
}
