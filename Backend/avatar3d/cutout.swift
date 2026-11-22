// Cuts the person out of a portrait, on this Mac, with Apple's Vision framework.
// Usage: cutout portrait.png cutout.png     Exit code 3: the picture does not show exactly one subject.
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(code)
}
guard CommandLine.arguments.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let photo = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Could not read the portrait.", 2) }

let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: photo, orientation: .up)
do { try handler.perform([request]) } catch { fail("Vision could not analyse the portrait.", 2) }
guard let result = request.results?.first, result.allInstances.count == 1,
      let mask = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler) else {
    fail("The portrait does not show exactly one subject.", 3)
}
let original = CIImage(cgImage: photo)
let matted = original.applyingFilter("CIBlendWithMask", parameters: [
    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: original.extent),
    kCIInputMaskImageKey: CIImage(cvPixelBuffer: mask),
])
guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let image = CIContext().createCGImage(matted, from: original.extent, format: .RGBA8, colorSpace: space),
      let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("Could not write the cutout.", 2)
}
CGImageDestinationAddImage(out, image, nil)
guard CGImageDestinationFinalize(out) else { fail("Could not write the cutout.", 2) }
