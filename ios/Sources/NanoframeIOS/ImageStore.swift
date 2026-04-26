import Foundation
import UIKit

// MARK: - Model

struct GalleryItem: Codable, Identifiable {
    let id: UUID
    let prompt: String
    let date: Date
    var contentId: String   // TV content ID (MY_F*); empty if not on TV
    let filename: String    // local JPEG in Documents/nanoframe/
}

// MARK: - Store

@MainActor
class ImageStore: ObservableObject {
    static let shared = ImageStore()

    @Published var items: [GalleryItem] = []

    private let dir: URL
    private let metaURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir     = docs.appendingPathComponent("nanoframe", isDirectory: true)
        metaURL = dir.appendingPathComponent("gallery.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Write

    /// Saves a JPEG to disk and adds it to the gallery.
    @discardableResult
    func add(jpeg: Data, prompt: String, contentId: String = "") -> GalleryItem {
        let id       = UUID()
        let filename = "\(id.uuidString).jpg"
        try? jpeg.write(to: dir.appendingPathComponent(filename))
        let item = GalleryItem(id: id, prompt: prompt, date: Date(),
                               contentId: contentId, filename: filename)
        items.insert(item, at: 0)
        persist()
        return item
    }

    /// Updates the TV content ID after a successful upload.
    func setContentId(_ contentId: String, for itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[idx].contentId = contentId
        persist()
    }

    /// Removes a gallery item and its local file.
    func delete(_ item: GalleryItem) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.filename))
        items.removeAll { $0.id == item.id }
        persist()
    }

    // MARK: - Read

    func image(for item: GalleryItem) -> UIImage? {
        UIImage(contentsOfFile: dir.appendingPathComponent(item.filename).path)
    }

    // MARK: - Persistence

    private func load() {
        guard let data   = try? Data(contentsOf: metaURL),
              let loaded = try? JSONDecoder().decode([GalleryItem].self, from: data) else { return }
        items = loaded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: metaURL)
    }
}
