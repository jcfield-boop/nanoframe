import Foundation
import AppKit
import CoreImage

struct ImageGenError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ImageProvider: String, CaseIterable {
    case pollinations = "pollinations"
    case nanoBanana   = "nano-banana"
    case gptImage1    = "gpt-image-1"
    case openAI       = "openai"

    var displayName: String {
        switch self {
        case .pollinations: return "Pollinations (free, no key)"
        case .nanoBanana:   return "Nano Banana"
        case .gptImage1:    return "GPT Image 1 (OpenAI)"
        case .openAI:       return "DALL·E 3 (OpenAI)"
        }
    }

    var needsKey: Bool { self != .pollinations }
}

struct DallEService {

    // MARK: - Public

    func generate(prompt: String, apiKey: String, provider: ImageProvider) async throws -> (jpeg: Data, image: NSImage) {
        let enhanced = Self.enhanceForFrameTV(prompt)
        switch provider {
        case .pollinations: return try await pollinations(prompt: enhanced)
        case .nanoBanana:   return try await nanoBanana(prompt: enhanced, apiKey: apiKey)
        case .gptImage1:    return try await gptImage1(prompt: enhanced, apiKey: apiKey)
        case .openAI:       return try await openAI(prompt: enhanced, apiKey: apiKey)
        }
    }

    /// Wraps the user's prompt with technical guidance optimised for the Samsung Frame TV (LS03A).
    /// The Frame has a matte anti-glare panel with a warm art-display profile — it rewards high
    /// contrast, rich saturation and sharp detail, and does not use HDR in art mode.
    static func enhanceForFrameTV(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed), highly detailed, 16:9 composition, wide color gamut, deep blacks, " +
               "rich saturated colors, high contrast, sharp fine detail, " +
               "professional photography or museum-quality art print, " +
               "optimised for matte anti-glare display, no HDR, no lens flare"
    }

    /// Only needed for OpenAI (1792×1024 → 3840×2160). Nano Banana returns 4K natively.
    func upscaleTo4K(_ jpegData: Data) -> Data? {
        guard let ci = CIImage(data: jpegData) else { return nil }
        let src = ci.extent.size
        guard src.width < 3000 else { return jpegData }   // already 4K, skip
        let scaled = ci.transformed(by: CGAffineTransform(
            scaleX: 3840.0 / src.width,
            y: 2160.0 / src.height
        ))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: 3840, height: 2160)) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    // MARK: - Pollinations.ai (free, no key)

    private func pollinations(prompt: String) async throws -> (jpeg: Data, image: NSImage) {
        let encoded = prompt.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? prompt
        let seed = Int.random(in: 1...999_999)
        // 1792×1024 — closest to 16:9 at high quality; we upscale to 4K for the TV
        guard let url = URL(string: "https://image.pollinations.ai/prompt/\(encoded)?width=1792&height=1024&model=flux&nologo=true&seed=\(seed)") else {
            throw ImageGenError(message: "Could not build Pollinations URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        try checkHTTP(response, data: data)
        return try decode(data)
    }

    // MARK: - Nano Banana (nanobanana.expert)

    private func nanoBanana(prompt: String, apiKey: String) async throws -> (jpeg: Data, image: NSImage) {
        let url = URL(string: "https://nanobanana.expert/api/v1/generate")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "prompt":        prompt,
            "aspect_ratio":  "16:9",
            "resolution":    "4k",         // native 4K — no upscaling needed
            "output_format": "jpg"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTP(response, data: data)

        guard let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr   = json["image_url"] as? String,
              let imageURL = URL(string: urlStr) else {
            throw ImageGenError(message: "No image_url in Nano Banana response")
        }

        let (imageData, _) = try await URLSession.shared.data(from: imageURL)
        return try decode(imageData)
    }

    // MARK: - GPT Image 1 (returns base64, native 1536×1024 landscape)

    private func gptImage1(prompt: String, apiKey: String) async throws -> (jpeg: Data, image: NSImage) {
        let url = URL(string: "https://api.openai.com/v1/images/generations")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model":              "gpt-image-1",
            "prompt":             prompt,
            "n":                  1,
            "size":               "1536x1024",   // native landscape — closest to 16:9
            "quality":            "high",
            "output_format":      "jpeg",
            "output_compression": 92
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTP(response, data: data)

        // gpt-image-1 always returns b64_json
        struct Resp: Decodable { struct Item: Decodable { let b64_json: String }; let data: [Item] }
        let result = try JSONDecoder().decode(Resp.self, from: data)
        guard let b64 = result.data.first?.b64_json,
              let imageData = Data(base64Encoded: b64) else {
            throw ImageGenError(message: "No image data in GPT Image 1 response")
        }
        return try decode(imageData)
    }

    // MARK: - OpenAI DALL·E 3

    private func openAI(prompt: String, apiKey: String) async throws -> (jpeg: Data, image: NSImage) {
        let url = URL(string: "https://api.openai.com/v1/images/generations")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "dall-e-3", "prompt": prompt,
            "n": 1, "size": "1792x1024", "quality": "hd"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTP(response, data: data)

        struct Resp: Decodable { struct Item: Decodable { let url: String }; let data: [Item] }
        let result = try JSONDecoder().decode(Resp.self, from: data)
        guard let urlStr = result.data.first?.url, let imageURL = URL(string: urlStr) else {
            throw ImageGenError(message: "No image URL in DALL·E response")
        }

        let (imageData, _) = try await URLSession.shared.data(from: imageURL)
        return try decode(imageData)
    }

    // MARK: - Helpers

    private func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let msg = (json["error"] as? [String: Any])?["message"] as? String
                    ?? json["message"] as? String
                    ?? json["error"] as? String
                    ?? "Unknown error"
                throw ImageGenError(message: msg)
            }
            throw ImageGenError(message: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
    }

    private func decode(_ data: Data) throws -> (jpeg: Data, image: NSImage) {
        guard let image = NSImage(data: data) else {
            throw ImageGenError(message: "Could not decode image")
        }
        guard let tiff   = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg   = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
            throw ImageGenError(message: "Failed to convert to JPEG")
        }
        return (jpeg, image)
    }
}
