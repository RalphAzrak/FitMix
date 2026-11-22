// Face landmarks with Apple's Vision framework, on-device. Usage: landmarks image.png  → JSON on stdout.
// Points are pixels with the origin at the top-left of the image.
import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count > 1,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("Could not read the image\n".data(using: .utf8)!); exit(2)
}
let size = CGSize(width: cg.width, height: cg.height)
let request = VNDetectFaceLandmarksRequest()
try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
var faces: [[String: Any]] = []
for face in request.results ?? [] {
    func points(_ region: VNFaceLandmarkRegion2D?) -> [[Double]] {
        (region?.pointsInImage(imageSize: size) ?? []).map { [Double($0.x), Double(size.height - $0.y)] }
    }
    let box = face.boundingBox
    var entry: [String: Any] = [
        "box": [box.minX * size.width, (1 - box.maxY) * size.height, box.width * size.width, box.height * size.height],
    ]
    if let marks = face.landmarks {
        entry["regions"] = [
            "faceContour": points(marks.faceContour), "leftEye": points(marks.leftEye), "rightEye": points(marks.rightEye),
            "leftEyebrow": points(marks.leftEyebrow), "rightEyebrow": points(marks.rightEyebrow),
            "nose": points(marks.nose), "noseCrest": points(marks.noseCrest), "medianLine": points(marks.medianLine),
            "outerLips": points(marks.outerLips), "innerLips": points(marks.innerLips),
            "leftPupil": points(marks.leftPupil), "rightPupil": points(marks.rightPupil),
        ]
    }
    faces.append(entry)
}
let json = try JSONSerialization.data(withJSONObject: ["width": cg.width, "height": cg.height, "faces": faces], options: [.sortedKeys])
FileHandle.standardOutput.write(json)
