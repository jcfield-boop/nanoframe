import Foundation
import UIKit
import CoreImage

struct ImageGenError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ImageProvider: String, CaseIterable {
    case pollinations  = "pollinations"
    case nanoBanana    = "nano-banana"
    case gptImage1     = "gpt-image-1"
    case gptImage1Mini = "gpt-image-1-mini"

    var displayName: String {
        switch self {
        case .pollinations:  return "Pollinations (free)"
        case .nanoBanana:    return "Nano Banana"
        case .gptImage1:     return "GPT Image 1 (OpenAI)"
        case .gptImage1Mini: return "GPT Image 1 Mini (OpenAI)"
        }
    }

    var needsKey: Bool { self != .pollinations }
}

struct DallEService {

    // MARK: - Public

    func generate(prompt: String, apiKey: String, provider: ImageProvider) async throws -> (jpeg: Data, image: UIImage) {
        let enhanced = Self.enhanceForFrameTV(prompt)
        switch provider {
        case .pollinations:  return try await pollinations(prompt: enhanced)
        case .nanoBanana:    return try await nanoBanana(prompt: enhanced, apiKey: apiKey)
        case .gptImage1:     return try await gptImageGen(prompt: enhanced, apiKey: apiKey, model: "gpt-image-1")
        case .gptImage1Mini: return try await gptImageGen(prompt: enhanced, apiKey: apiKey, model: "gpt-image-1-mini")
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

    /// Upscales to 3840×2160 if the image is smaller. Returns nil on failure (caller keeps original).
    func upscaleTo4K(_ jpegData: Data) -> Data? {
        guard let ci = CIImage(data: jpegData) else { return nil }
        let src = ci.extent.size
        guard src.width < 3000 else { return jpegData }   // already large enough, skip

        let scaled = ci.transformed(by: CGAffineTransform(
            scaleX: 3840.0 / src.width,
            y: 2160.0 / src.height
        ))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: 3840, height: 2160)) else {
            return nil
        }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.92)
    }

    // MARK: - Pollinations.ai (free, no key)

    private func pollinations(prompt: String) async throws -> (jpeg: Data, image: UIImage) {
        let encoded = prompt.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? prompt
        let seed = Int.random(in: 1...999_999)
        guard let url = URL(string: "https://image.pollinations.ai/prompt/\(encoded)?width=1792&height=1024&model=flux&nologo=true&seed=\(seed)") else {
            throw ImageGenError(message: "Could not build Pollinations URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        try checkHTTP(response, data: data)
        return try decode(data)
    }

    // MARK: - Nano Banana

    private func nanoBanana(prompt: String, apiKey: String) async throws -> (jpeg: Data, image: UIImage) {
        let url = URL(string: "https://nanobanana.expert/api/v1/generate")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "prompt":        prompt,
            "aspect_ratio":  "16:9",
            "resolution":    "4k",
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

    // MARK: - GPT Image (gpt-image-1 and gpt-image-1-mini)
    // Both models return b64_json and support 1536×1024 landscape.
    // Mini is faster and cheaper; full is higher quality.

    private func gptImageGen(prompt: String, apiKey: String, model: String) async throws -> (jpeg: Data, image: UIImage) {
        let url = URL(string: "https://api.openai.com/v1/images/generations")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model":              model,
            "prompt":             prompt,
            "n":                  1,
            "size":               "1536x1024",
            "quality":            model.hasSuffix("mini") ? "medium" : "high",
            "output_format":      "jpeg",
            "output_compression": 92
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTP(response, data: data)

        struct Resp: Decodable { struct Item: Decodable { let b64_json: String }; let data: [Item] }
        let result = try JSONDecoder().decode(Resp.self, from: data)
        guard let b64 = result.data.first?.b64_json,
              let imageData = Data(base64Encoded: b64) else {
            throw ImageGenError(message: "No image data in \(model) response")
        }
        return try decode(imageData)
    }

    // MARK: - Helpers

    private func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let msg = (json["error"] as? [String: Any])?["message"] as? String
                    ?? json["message"] as? String
                    ?? json["error"]   as? String
                    ?? "Unknown error"
                throw ImageGenError(message: msg)
            }
            throw ImageGenError(message: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
    }

    private func decode(_ data: Data) throws -> (jpeg: Data, image: UIImage) {
        guard let image = UIImage(data: data) else {
            throw ImageGenError(message: "Could not decode image")
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.95) else {
            throw ImageGenError(message: "Failed to convert to JPEG")
        }
        return (jpeg, image)
    }
}
