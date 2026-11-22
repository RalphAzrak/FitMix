import CoreGraphics
import Foundation
import Vision

// MARK: - What the phone reads on a garment crop (on-device, after the tap)
//
// The clues travel with the crop to the backend, which uses them to search and to decide how sure a match is:
// - text: every word or code printed on the garment (Vision text recognition), e.g. "converse", "dd8959-100".
// - color: measured on the person's pixels at detection, else the crop's centre if one colour dominates.
// - pattern / style: from Vision's image classifier ("polka dots", "leopard"; "sneaker", "boot", "hoodie"…).
//   Vision has no stripes/plaid/logo labels, so those aren't detected; printed text counts as "text print".
//
// `VisualSimilarity` compares the crop with listing photos (Vision feature prints) so the closest-looking
// listings rank first within each match tier. Nothing here touches the network.

nonisolated struct GarmentClueSet: Sendable, Equatable {
    var color: String?
    var text: [String] = []
    var pattern: String?
    var style: String?
}

nonisolated enum GarmentClues {
    static func read(category: GarmentCategory, crop: CGImage, measuredColor: SIMD3<Float>?) -> GarmentClueSet {
        let text = words(in: crop)
        let labels = classifierLabels(crop)
        var clues = GarmentClueSet()
        clues.color = measuredColor.flatMap(colorName(of:)) ?? dominantColorName(of: crop)
        clues.text = Array(text.prefix(12))
        if (labels["polka_dots"] ?? 0) >= 0.2 { clues.pattern = "polka dots" }
        else if (labels["leopard"] ?? 0) >= 0.2 { clues.pattern = "leopard" }
        else if text.count >= 2 && category != .shoes { clues.pattern = "text print" }
        let styles: [GarmentCategory: [String]] = [
            .shoes: ["sneaker", "boot", "high_heel", "loafer", "sandal"],
            .jacket: ["hoodie", "suit"],
            .pants: ["jeans"],
        ]
        clues.style = styles[category]?.map { ($0, labels[$0] ?? 0) }.filter { $0.1 >= 0.15 }.max { $0.1 < $1.1 }?.0
        return clues
    }

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

    static func classifierLabels(_ image: CGImage) -> [String: Float] {
        let request = VNClassifyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])) != nil else { return [:] }
        var labels: [String: Float] = [:]
        for observation in request.results ?? [] where observation.confidence > 0.05 { labels[observation.identifier] = observation.confidence }
        return labels
    }

    /// The crop's central colour, only when most of the centre is that one colour.
    static func dominantColorName(of image: CGImage) -> String? {
        guard let grid = ColorGrid(image, maxWidth: 48) else { return nil }
        let centre = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        guard let mean = grid.mean(in: centre, mask: nil) else { return nil }
        var near = 0, total = 0
        for y in stride(from: centre.minY, to: centre.maxY, by: 1 / Double(grid.height)) {
            for x in stride(from: centre.minX, to: centre.maxX, by: 1 / Double(grid.width)) {
                let cell = CGRect(x: x, y: y, width: 0.5 / Double(grid.width), height: 0.5 / Double(grid.height))
                guard let c = grid.mean(in: cell, mask: nil) else { continue }
                total += 1
                if deltaE(c, mean) < 15 { near += 1 }
            }
        }
        guard total > 0, Double(near) / Double(total) >= 0.6 else { return nil }
        return colorName(of: mean)
    }

    /// The nearest name from a small fixed palette, or nil if none is close.
    static func colorName(of mean: SIMD3<Float>) -> String? {
        let palette: [(String, SIMD3<Float>)] = [
            ("black", [0.08, 0.08, 0.08]), ("white", [0.95, 0.95, 0.95]), ("gray", [0.55, 0.55, 0.55]),
            ("navy", [0.10, 0.14, 0.32]), ("blue", [0.20, 0.40, 0.80]), ("light blue", [0.60, 0.75, 0.90]),
            ("red", [0.80, 0.12, 0.12]), ("burgundy", [0.45, 0.08, 0.15]), ("pink", [0.95, 0.65, 0.75]),
            ("orange", [0.95, 0.50, 0.10]), ("yellow", [0.95, 0.85, 0.20]), ("beige", [0.85, 0.78, 0.65]),
            ("brown", [0.45, 0.30, 0.18]), ("olive", [0.40, 0.42, 0.20]), ("green", [0.15, 0.55, 0.25]),
            ("purple", [0.45, 0.25, 0.60]),
        ]
        guard let best = palette.min(by: { deltaE(mean, $0.1) < deltaE(mean, $1.1) }), deltaE(mean, best.1) < 25 else { return nil }
        return best.0
    }
}

/// How alike two images look, from Vision's image feature prints (0 = identical, larger = less alike).
nonisolated enum VisualSimilarity {
    static func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFit
        guard (try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])) != nil else { return nil }
        return request.results?.first
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        guard (try? a.computeDistance(&distance, to: b)) != nil else { return nil }
        return distance
    }
}
