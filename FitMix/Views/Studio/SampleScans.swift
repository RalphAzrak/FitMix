#if DEBUG
import SwiftUI
import UIKit

/// Debug-only stand-ins for the Camera's output, so Studio can be exercised before the real
/// scanner lands. Compiled out of release builds and reachable only from the Camera placeholder:
/// - FM_DEBUG_SAMPLE_SCANS=1: two illustrated scans drawn in code (no bundled assets).
/// - FM_DEBUG_SCAN_FIXTURE=/path/to/folder: a real photo with hand-entered garment data (scan.json).
enum SampleScans {
    enum Kind { case illustration, fixture }

    private static var issued: [UUID: Kind] = [:]

    static var enabled: Bool { ProcessInfo.processInfo.environment["FM_DEBUG_SAMPLE_SCANS"] == "1" }

    static var fixtureFolder: URL? {
        ProcessInfo.processInfo.environment["FM_DEBUG_SCAN_FIXTURE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func kind(of scan: OutfitScan) -> Kind? { issued[scan.id] }

    private static let canvas = CGSize(width: 600, height: 900)

    // MARK: Scan A — four pieces, cutouts, catalog matches with prices

    static func scanA() -> OutfitScan {
        let jacket = Piece.jacket(color: UIColor(red: 0.36, green: 0.40, blue: 0.24, alpha: 1))
        let top = Piece.tee(color: UIColor(white: 0.97, alpha: 1))
        let pants = Piece.jeans(color: UIColor(red: 0.12, green: 0.18, blue: 0.33, alpha: 1))
        let shoes = Piece.sneakers(color: UIColor(red: 0.93, green: 0.90, blue: 0.84, alpha: 1))
        let image = scene(wall: UIColor(red: 0.86, green: 0.83, blue: 0.77, alpha: 1), pieces: [shoes, pants, top, jacket])

        let garments = [
            DetectedGarment(category: .jacket, label: "Olive bomber", bounds: norm(jacket.bounds), cutout: cutout(jacket),
                            matches: [
                                product("jk-olive", "Olive Bomber", "Northline", .jacket, .exact, jacket, 148, ["XS", "S", "M", "L"]),
                                product("jk-black", "Black Bomber", "Northline", .jacket, .similar,
                                        Piece.jacket(color: UIColor(white: 0.12, alpha: 1)), nil, ["S", "M"]),
                            ]),
            DetectedGarment(category: .top, label: "Boxy chalk tee", bounds: norm(top.bounds), cutout: cutout(top),
                            matches: [product("tp-chalk", "Boxy Chalk Tee", "Studio Basics", .top, .exact, top, 38, ["S", "M", "L", "XL"])]),
            DetectedGarment(category: .pants, label: "Dark-wash straight jeans", bounds: norm(pants.bounds), cutout: cutout(pants),
                            matches: [
                                product("pn-indigo", "Indigo Straight Jean", "Raw & Co", .pants, .similar, pants, 110, ["28×30", "30×30", "32×30", "34×32"]),
                                product("pn-raw", "Raw Denim Straight", "Raw & Co", .pants, .exact,
                                        Piece.jeans(color: UIColor(red: 0.07, green: 0.11, blue: 0.22, alpha: 1)), 125, ["30×30", "32×30", "34×30"]),
                                product("pn-light", "Light Wash Straight", "Raw & Co", .pants, .similar,
                                        Piece.jeans(color: UIColor(red: 0.53, green: 0.65, blue: 0.80, alpha: 1)), 98, ["28×30", "30×32"]),
                            ]),
            DetectedGarment(category: .shoes, label: "Retro cream sneakers", bounds: norm(shoes.bounds), cutout: cutout(shoes),
                            matches: [product("sh-cream", "Retro Cream Sneaker", "Courtside", .shoes, .exact, shoes, 89, ["7", "8", "9", "10", "11"])]),
        ]
        return issue(OutfitScan(image: image, subjectBounds: CGRect(x: 0.22, y: 0.08, width: 0.56, height: 0.88), garments: garments))
    }

    // MARK: Scan B — partial: crop-only piece, no matches, a piece with no image or region

    static func scanB() -> OutfitScan {
        let top = Piece.knit(color: UIColor(red: 0.13, green: 0.17, blue: 0.30, alpha: 1))
        let skirt = Piece.skirt(color: UIColor(red: 0.66, green: 0.33, blue: 0.19, alpha: 1))
        let boots = Piece.boots(color: UIColor(white: 0.10, alpha: 1))
        let image = scene(wall: UIColor(red: 0.78, green: 0.82, blue: 0.80, alpha: 1), pieces: [boots, skirt, top])

        let garments = [
            DetectedGarment(category: .top, label: "Navy rib knit", bounds: norm(top.bounds), cutout: cutout(top),
                            matches: [
                                product("kn-navy", "Rib Knit Sweater", "Fold", .top, .similar, top, 64, []),
                                product("kn-oat", "Rib Knit Sweater, Oat", "Fold", .top, .similar,
                                        Piece.knit(color: UIColor(red: 0.88, green: 0.83, blue: 0.74, alpha: 1)), 64, ["S", "M"]),
                            ]),
            // Crop only, no catalog match.
            DetectedGarment(category: .skirt, label: nil, bounds: norm(skirt.bounds), cutout: nil, crop: crop(image, skirt.bounds)),
            // Detected but nothing else came back.
            DetectedGarment(category: .shoes),
        ]
        return issue(OutfitScan(image: image, garments: garments))
    }

    // MARK: Drawing

    private struct Piece {
        var bounds: CGRect
        var draw: (CGContext) -> Void

        static func tee(color: UIColor) -> Piece {
            Piece(bounds: CGRect(x: 238, y: 222, width: 124, height: 262)) { c in
                c.setFillColor(color.cgColor)
                c.fill(CGRect(x: 238, y: 222, width: 124, height: 262))
                c.setStrokeColor(UIColor(white: 0, alpha: 0.12).cgColor); c.setLineWidth(2)
                c.stroke(CGRect(x: 238, y: 222, width: 124, height: 262))
            }
        }

        static func jacket(color: UIColor) -> Piece {
            Piece(bounds: CGRect(x: 150, y: 212, width: 300, height: 278)) { c in
                c.setFillColor(color.cgColor)
                // Left and right panels, open at the front.
                c.addPath(UIBezierPath(roundedRect: CGRect(x: 188, y: 212, width: 88, height: 278), cornerRadius: 18).cgPath)
                c.addPath(UIBezierPath(roundedRect: CGRect(x: 324, y: 212, width: 88, height: 278), cornerRadius: 18).cgPath)
                // Sleeves.
                c.addPath(UIBezierPath(roundedRect: CGRect(x: 150, y: 222, width: 56, height: 250), cornerRadius: 24).cgPath)
                c.addPath(UIBezierPath(roundedRect: CGRect(x: 394, y: 222, width: 56, height: 250), cornerRadius: 24).cgPath)
                c.fillPath()
                // Ribbed hem.
                c.setFillColor(UIColor(white: 0, alpha: 0.18).cgColor)
                c.fill(CGRect(x: 188, y: 470, width: 88, height: 20)); c.fill(CGRect(x: 324, y: 470, width: 88, height: 20))
            }
        }

        static func knit(color: UIColor) -> Piece {
            Piece(bounds: CGRect(x: 160, y: 214, width: 280, height: 266)) { c in
                c.setFillColor(color.cgColor)
                c.addPath(UIBezierPath(roundedRect: CGRect(x: 196, y: 214, width: 208, height: 266), cornerRadius: 22).cgPath)
                c.addPath(UIBezierPath(roundedRect: CGRect(x: 160, y: 226, width: 54, height: 240), cornerRadius: 24).cgPath)
                c.addPath(UIBezierPath(roundedRect: CGRect(x: 386, y: 226, width: 54, height: 240), cornerRadius: 24).cgPath)
                c.fillPath()
                c.setStrokeColor(UIColor(white: 1, alpha: 0.12).cgColor); c.setLineWidth(3)
                for x in stride(from: 212, to: 400, by: 14) {
                    c.move(to: CGPoint(x: x, y: 230)); c.addLine(to: CGPoint(x: x, y: 470))
                }
                c.strokePath()
            }
        }

        static func jeans(color: UIColor) -> Piece {
            Piece(bounds: CGRect(x: 232, y: 470, width: 136, height: 336)) { c in
                c.setFillColor(color.cgColor)
                c.fill(CGRect(x: 232, y: 470, width: 136, height: 60))
                c.addPath(UIBezierPath(roundedRect: CGRect(x: 232, y: 500, width: 64, height: 306), cornerRadius: 10).cgPath)
                c.addPath(UIBezierPath(roundedRect: CGRect(x: 304, y: 500, width: 64, height: 306), cornerRadius: 10).cgPath)
                c.fillPath()
                c.setStrokeColor(UIColor(white: 1, alpha: 0.18).cgColor); c.setLineWidth(2)
                c.move(to: CGPoint(x: 300, y: 476)); c.addLine(to: CGPoint(x: 300, y: 530)); c.strokePath()
            }
        }

        static func skirt(color: UIColor) -> Piece {
            Piece(bounds: CGRect(x: 214, y: 470, width: 172, height: 210)) { c in
                c.setFillColor(color.cgColor)
                c.move(to: CGPoint(x: 240, y: 470)); c.addLine(to: CGPoint(x: 360, y: 470))
                c.addLine(to: CGPoint(x: 386, y: 680)); c.addLine(to: CGPoint(x: 214, y: 680)); c.closePath()
                c.fillPath()
            }
        }

        static func sneakers(color: UIColor) -> Piece {
            Piece(bounds: CGRect(x: 214, y: 796, width: 172, height: 46)) { c in
                c.setFillColor(color.cgColor)
                c.fillEllipse(in: CGRect(x: 214, y: 796, width: 84, height: 46))
                c.fillEllipse(in: CGRect(x: 302, y: 796, width: 84, height: 46))
                c.setFillColor(UIColor(white: 0.55, alpha: 1).cgColor)
                c.fill(CGRect(x: 222, y: 832, width: 68, height: 6)); c.fill(CGRect(x: 310, y: 832, width: 68, height: 6))
            }
        }

        static func boots(color: UIColor) -> Piece {
            Piece(bounds: CGRect(x: 226, y: 700, width: 148, height: 140)) { c in
                c.setFillColor(color.cgColor)
                c.addPath(UIBezierPath(roundedRect: CGRect(x: 236, y: 700, width: 56, height: 140), cornerRadius: 12).cgPath)
                c.addPath(UIBezierPath(roundedRect: CGRect(x: 308, y: 700, width: 56, height: 140), cornerRadius: 12).cgPath)
                c.addPath(UIBezierPath(roundedRect: CGRect(x: 226, y: 810, width: 70, height: 30), cornerRadius: 10).cgPath)
                c.addPath(UIBezierPath(roundedRect: CGRect(x: 304, y: 810, width: 70, height: 30), cornerRadius: 10).cgPath)
                c.fillPath()
            }
        }
    }

    private static func renderer() -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: canvas, format: format)
    }

    /// The whole person on a wall, like a captured frame.
    private static func scene(wall: UIColor, pieces: [Piece]) -> UIImage {
        renderer().image { ctx in
            let c = ctx.cgContext
            wall.setFill(); c.fill(CGRect(origin: .zero, size: canvas))
            UIColor(white: 0, alpha: 0.06).setFill(); c.fill(CGRect(x: 0, y: 760, width: canvas.width, height: 140))
            c.setFillColor(UIColor(white: 0, alpha: 0.12).cgColor)
            c.fillEllipse(in: CGRect(x: 190, y: 826, width: 220, height: 30))
            let skin = UIColor(red: 0.84, green: 0.67, blue: 0.55, alpha: 1)
            skin.setFill()
            c.fill(CGRect(x: 248, y: 300, width: 104, height: 500))        // body under clothes
            c.fill(CGRect(x: 280, y: 190, width: 40, height: 40))           // neck
            c.fillEllipse(in: CGRect(x: 245, y: 90, width: 110, height: 125)) // head
            c.fillEllipse(in: CGRect(x: 156, y: 460, width: 44, height: 44)) // hands
            c.fillEllipse(in: CGRect(x: 400, y: 460, width: 44, height: 44))
            c.fill(CGRect(x: 246, y: 660, width: 40, height: 150)); c.fill(CGRect(x: 314, y: 660, width: 40, height: 150)) // legs
            UIColor(red: 0.22, green: 0.15, blue: 0.11, alpha: 1).setFill()
            c.addPath(UIBezierPath(roundedRect: CGRect(x: 238, y: 78, width: 124, height: 70), cornerRadius: 34).cgPath); c.fillPath()
            for piece in pieces { piece.draw(c) }
        }
    }

    /// The garment alone on a transparent background, trimmed to its region.
    private static func cutout(_ piece: Piece) -> UIImage {
        let full = renderer().image { ctx in piece.draw(ctx.cgContext) }
        return crop(full, piece.bounds)
    }

    private static func crop(_ image: UIImage, _ rect: CGRect) -> UIImage {
        let scaled = CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
                            width: rect.width * image.scale, height: rect.height * image.scale)
        guard let cg = image.cgImage?.cropping(to: scaled) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
    }

    private static func norm(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX / canvas.width, y: rect.minY / canvas.height,
               width: rect.width / canvas.width, height: rect.height / canvas.height)
    }

    private static func product(_ id: String, _ name: String, _ brand: String, _ category: GarmentCategory,
                                _ match: CatalogProduct.Match, _ piece: Piece, _ usd: Int?, _ sizes: [String]) -> CatalogProduct {
        CatalogProduct(id: id, name: name, brand: brand, category: category, match: match,
                       image: .local(cutout(piece)),
                       price: usd.map { Price(amount: Decimal($0), currencyCode: "USD") },
                       sizes: sizes, retailerURL: nil)
    }

    private static func issue(_ scan: OutfitScan, as kind: Kind = .illustration) -> OutfitScan {
        issued[scan.id] = kind
        return scan
    }

    /// Labels a scan built elsewhere (from `liveSelection`) as sample data.
    static func register(_ scan: OutfitScan, as kind: Kind = .illustration) {
        issued[scan.id] = kind
    }

    // MARK: Live selection stand-in

    /// Sample Scan A's illustration as if its `category` had been tapped in the live camera, for
    /// testing Studio's retailer search without a camera. The "Top" is treated as the T-shirt.
    static func liveSelection(_ category: GarmentCategory) -> LiveGarmentSelection? {
        let scan = scanA()
        guard let frame = scan.image.cgImage else { return nil }
        let garments = scan.garments.compactMap { garment -> LiveGarmentSelection.Garment? in
            let live: GarmentCategory = garment.category == .top ? .tshirt : garment.category
            guard GarmentCategory.liveScannable.contains(live), let bounds = garment.bounds,
                  let crop = LiveGarmentSelection.crop(frame, to: bounds) else { return nil }
            return LiveGarmentSelection.Garment(category: live, bounds: bounds, crop: crop)
        }
        guard garments.contains(where: { $0.category == category }) else { return nil }
        var selection = LiveGarmentSelection(frame: frame, capturedAt: .now, garments: garments, selected: category)
        selection.isSample = true
        return selection
    }

    // MARK: Photo fixture

    struct FixtureError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Builds a scan from a real photo plus hand-entered garment data, the same shape the Camera
    /// will produce. Regions are normalized to the photo as you see it (0–1, top-left origin).
    static func fixtureScan(from folder: URL) throws -> OutfitScan {
        let jsonURL = folder.appendingPathComponent("scan.json")
        guard let data = try? Data(contentsOf: jsonURL) else {
            throw FixtureError(message: "Couldn't read \(jsonURL.path).")
        }
        let spec: FixtureSpec
        do { spec = try JSONDecoder().decode(FixtureSpec.self, from: data) } catch {
            throw FixtureError(message: "scan.json isn't valid: \(error.localizedDescription)")
        }
        func load(_ name: String?) -> UIImage? {
            name.flatMap { UIImage(contentsOfFile: folder.appendingPathComponent($0).path) }
        }
        guard let original = load(spec.photo) else {
            throw FixtureError(message: "Couldn't open the photo \(spec.photo) in \(folder.path).")
        }
        // Upright, like a camera frame after orientation is applied.
        let photo = original.normalized(maxDimension: 3000)

        let garments = try spec.garments.enumerated().map { index, g -> DetectedGarment in
            guard let category = GarmentCategory(rawValue: g.category) else {
                throw FixtureError(message: "Garment \(index + 1): unknown category \"\(g.category)\". Use one of: \(GarmentCategory.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let bounds = try g.bounds.map { try rect($0, "garment \(index + 1) bounds") }
            let crop = load(g.crop) ?? bounds.map { cropPhoto(photo, $0) }
            let matches = try (g.matches ?? []).map { m -> CatalogProduct in
                CatalogProduct(id: m.id, name: m.name, brand: m.brand, category: category,
                               match: m.match == "exact" ? .exact : .similar,
                               image: load(m.image).map { .local($0) } ?? m.imageURL.flatMap(URL.init(string:)).map { .remote($0) },
                               price: try m.price.map { amount in
                                   guard let code = m.currency else { throw FixtureError(message: "\(m.name): price needs a currency, e.g. \"USD\".") }
                                   return Price(amount: Decimal(amount), currencyCode: code)
                               },
                               sizes: m.sizes ?? [], retailerURL: m.url.flatMap(URL.init(string:)))
            }
            return DetectedGarment(category: category, label: g.label, bounds: bounds,
                                   cutout: load(g.cutout), crop: crop, matches: matches)
        }
        let subject = try spec.subject.map { try rect($0, "subject") }
        return issue(OutfitScan(image: photo, subjectBounds: subject, garments: garments), as: .fixture)
    }

    private static func rect(_ values: [Double], _ name: String) throws -> CGRect {
        guard values.count == 4, values.allSatisfy({ (0...1).contains($0) }) else {
            throw FixtureError(message: "\(name) must be [x, y, width, height] with values from 0 to 1.")
        }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    /// Stand-in for the pipeline's crop: the garment's region cut from the photo.
    private static func cropPhoto(_ photo: UIImage, _ bounds: CGRect) -> UIImage {
        let px = CGRect(x: bounds.minX * photo.size.width * photo.scale, y: bounds.minY * photo.size.height * photo.scale,
                        width: bounds.width * photo.size.width * photo.scale, height: bounds.height * photo.size.height * photo.scale).integral
        guard let cg = photo.cgImage?.cropping(to: px) else { return photo }
        return UIImage(cgImage: cg, scale: photo.scale, orientation: .up)
    }

    private struct FixtureSpec: Decodable {
        var photo: String
        var subject: [Double]?
        var garments: [Garment]

        struct Garment: Decodable {
            var category: String
            var label: String?
            var bounds: [Double]?
            var cutout: String?
            var crop: String?
            var matches: [Match]?
        }

        struct Match: Decodable {
            var id: String
            var name: String
            var brand: String?
            var match: String
            var price: Double?
            var currency: String?
            var sizes: [String]?
            var image: String?
            var imageURL: String?
            var url: String?
        }
    }
}
#endif
