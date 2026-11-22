import CoreGraphics
import Foundation
import Vision

nonisolated enum GarmentClues {
    /// Words and codes printed on the garment, lowercased, in reading order, without repeats.
    static func words(in image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])) != nil else { return [] }
        var words: [String] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.4 else { continue }
            // Keep hyphens inside codes ("DD8959-100"); split on everything else.
            for raw in candidate.string.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") }) {
                let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
                if token.count >= 2, !words.contains(token) { words.append(token) }
            }
        }
        return words
    }
}
