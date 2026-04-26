import Foundation
import AppKit

// MARK: - NSImage helpers

extension NSImage {
    var jpegData: Data? {
        guard let tiff   = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
    }
}

// MARK: - Model

struct GalleryItem: Codable, Identifiable {
    let id: UUID
    let prompt: String
    let date: Date
    var contentId: String   // TV content ID (MY_F*); empty if not on TV
    let filename: String    // local JPEG in ~/Library/Application Support/Nanoframe/
}

// MARK: - Store

@MainActor
class ImageStore: ObservableObject {
    static let shared = ImageStore()

    @Published var items: [GalleryItem] = []

    private let dir: URL
    private let metaURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir     = appSupport.appendingPathComponent("Nanoframe", isDirectory: true)
        metaURL = dir.appendingPathComponent("gallery.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Write

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

    func setContentId(_ contentId: String, for itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[idx].contentId = contentId
        persist()
    }

    func delete(_ item: GalleryItem) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.filename))
        items.removeAll { $0.id == item.id }
        persist()
    }

    // MARK: - Read

    func image(for item: GalleryItem) -> NSImage? {
        NSImage(contentsOf: dir.appendingPathComponent(item.filename))
    }

    /// Opens an NSSavePanel so the user can save a JPEG wherever they like.
    func saveToFile(_ jpeg: Data, prompt: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        let safe = prompt.prefix(40)
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = safe.isEmpty ? "nanoframe" : safe
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? jpeg.write(to: url)
        }
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
