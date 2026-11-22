import Foundation
import Observation
import UIKit

nonisolated struct SavedLook: Identifiable, Codable {
    nonisolated enum Kind: String, Codable { case preview, scan }

    nonisolated struct Piece: Codable {
        let slot: AvatarOutfitSlot?
        let itemID: UUID?
        let name: String
    }

    let id: UUID
    let createdAt: Date
    let kind: Kind
    let pieces: [Piece]

    var title: String {
        if kind == .scan { return "Scanned Outfit" }
        return pieces.first?.name ?? "Outfit"
    }
    var itemCount: String { pieces.count == 1 ? "1 piece" : "\(pieces.count) pieces" }
    var canReuse: Bool { pieces.contains { $0.slot != nil && $0.itemID != nil } }
}

@MainActor @Observable
final class SavedLookStore {
    private(set) var looks: [SavedLook] = []
    private(set) var error: String?

    @ObservationIgnored private var ownerID: UUID?
    @ObservationIgnored private var activation = UUID()

    func activate(ownerID: UUID?) {
        guard self.ownerID != ownerID else { return }
        self.ownerID = ownerID
        activation = UUID()
        reload()
    }

    func reload() {
        looks = []
        error = nil
        guard let folder else { return }
        do {
            let index = folder.appending(path: "looks.json")
            guard FileManager.default.fileExists(atPath: index.path(percentEncoded: false)) else { return }
            looks = try JSONDecoder().decode([SavedLook].self, from: Data(contentsOf: index))
        } catch {
            self.error = "Couldn't open your saved looks."
        }
    }

    func imageURL(for look: SavedLook, thumbnail: Bool = false) -> URL? {
        folder?.appending(path: "\(look.id.uuidString)-\(thumbnail ? "thumb" : "preview").jpg")
    }

    func save(image: UIImage, pieces: [SavedLook.Piece], ownerID: UUID?,
              kind: SavedLook.Kind = .preview) async throws -> SavedLook {
        guard let ownerID, ownerID == self.ownerID, let folder, error == nil else { throw SaveError.unavailable }
        let session = activation
        async let previewData = image.uploadJPEG(maxDimension: 1440, quality: 0.89)
        async let thumbnailData = image.uploadJPEG(maxDimension: 440, quality: 0.83)
        guard let preview = await previewData, let thumbnail = await thumbnailData else { throw SaveError.image }
        try Task.checkCancellation()
        guard session == activation, error == nil else { throw SaveError.unavailable }
        let look = SavedLook(id: UUID(), createdAt: .now, kind: kind, pieces: pieces)
        guard let previewURL = imageURL(for: look), let thumbnailURL = imageURL(for: look, thumbnail: true) else {
            throw SaveError.unavailable
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try preview.write(to: previewURL, options: [.atomic, .completeFileProtection])
            try thumbnail.write(to: thumbnailURL, options: [.atomic, .completeFileProtection])
            try replaceIndex([look] + looks, in: folder)
            return look
        } catch {
            try? FileManager.default.removeItem(at: previewURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
            throw error
        }
    }

    func remove(_ look: SavedLook) throws {
        guard let folder, error == nil, looks.contains(where: { $0.id == look.id }) else {
            throw SaveError.unavailable
        }
        try replaceIndex(looks.filter { $0.id != look.id }, in: folder)
        for thumbnail in [false, true] {
            if let url = imageURL(for: look, thumbnail: thumbnail) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private var folder: URL? {
        ownerID.map { URL.applicationSupportDirectory.appending(path: "SavedLooks").appending(path: $0.uuidString) }
    }

    private func replaceIndex(_ records: [SavedLook], in folder: URL) throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: folder.appending(path: "looks.json"), options: [.atomic, .completeFileProtection])
        looks = records
    }

    private enum SaveError: Error { case unavailable, image }
}
