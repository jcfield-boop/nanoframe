import Foundation
import AppKit
import CoreImage

struct ImageGenError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ImageProvider: String, CaseIterable {
    case pollinations     = "pollinations"
    case falFluxSchnell   = "fal-flux-schnell"
    case falFluxPro       = "fal-flux-pro"
    case gptImageSunburst = "gpt-image-2.5-sunburst"
    case gptImageFlare    = "gpt-image-2.5-flare"

    var displayName: String {
        switch self {
        case .pollinations:     return "Pollinations (free)"
        case .falFluxSchnell:   return "Flux Schnell — fal.ai"
        case .falFluxPro:       return "Flux Pro — fal.ai"
        case .gptImageSunburst: return "GPT Image 2.5 Sunburst — OpenAI (premium)"
        case .gptImageFlare:    return "GPT Image 2.5 Flare — OpenAI (fast)"
        }
    }

    var needsKey: Bool { self != .pollinations }
    var needsFalKey: Bool { self == .falFluxSchnell || self == .falFluxPro }
    var needsOpenAIKey: Bool { self == .gptImageSunburst || self == .gptImageFlare }
}

struct DallEService {

    // MARK: - Public

    func generate(prompt: String, apiKey: String, provider: ImageProvider) async throws -> (jpeg: Data, image: NSImage) {
        let enhanced = Self.enhanceForFrameTV(prompt)
        switch provider {
        case .pollinations:
            return try await pollinations(prompt: enhanced)
        case .falFluxSchnell:
            return try await falGenerate(modelId: "fal-ai/flux/schnell", prompt: enhanced, apiKey: apiKey)
        case .falFluxPro:
            return try await falGenerate(modelId: "fal-ai/flux-pro/v1.1", prompt: enhanced, apiKey: apiKey)
        case .gptImageSunburst:
            return try await gptImageGen(prompt: enhanced, apiKey: apiKey, model: provider.rawValue, quality: "high")
        case .gptImageFlare:
            return try await gptImageGen(prompt: enhanced, apiKey: apiKey, model: provider.rawValue, quality: "medium")
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

    /// Only needed when a provider returns smaller than 4K; fal.ai and GPT Image are upscaled here.
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

    // MARK: - fal.ai — Flux Schnell & Flux Pro
    // Uses fal.ai's async queue: submit → poll status → fetch result.
    // Images are returned as CDN URLs, so we download them after completion.

    private func falGenerate(modelId: String, prompt: String, apiKey: String) async throws -> (jpeg: Data, image: NSImage) {
        guard let submitURL = URL(string: "https://queue.fal.run/\(modelId)") else {
            throw ImageGenError(message: "Invalid fal.ai model ID")
        }
        var req = URLRequest(url: submitURL)
        req.httpMethod = "POST"
        req.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt,
            "image_size": "landscape_16_9",
            "num_images": 1,
            "enable_safety_checker": false
        ])

        let (submitData, submitResp) = try await URLSession.shared.data(for: req)
        try checkHTTP(submitResp, data: submitData)

        guard let submitJSON = try? JSONSerialization.jsonObject(with: submitData) as? [String: Any],
              let requestId = submitJSON["request_id"] as? String else {
            throw ImageGenError(message: "No request_id in fal.ai response")
        }

        let base = "https://queue.fal.run/\(modelId)/requests/\(requestId)"
        guard let statusURL = URL(string: "\(base)/status") else {
            throw ImageGenError(message: "Could not build fal.ai status URL")
        }

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 2_000_000_000)

            var pollReq = URLRequest(url: statusURL)
            pollReq.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
            guard let (sd, _) = try? await URLSession.shared.data(for: pollReq),
                  let sj = try? JSONSerialization.jsonObject(with: sd) as? [String: Any],
                  let status = sj["status"] as? String else { continue }

            if status == "FAILED" {
                let detail = sj["error"] as? String ?? "unknown error"
                throw ImageGenError(message: "fal.ai generation failed: \(detail)")
            }
            guard status == "COMPLETED" else { continue }

            guard let resultURL = URL(string: base) else {
                throw ImageGenError(message: "Could not build fal.ai result URL")
            }
            var resultReq = URLRequest(url: resultURL)
            resultReq.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
            let (resultData, resultResp) = try await URLSession.shared.data(for: resultReq)
            try checkHTTP(resultResp, data: resultData)

            guard let rj = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
                  let images = rj["images"] as? [[String: Any]],
                  let urlStr = images.first?["url"] as? String,
                  let imageURL = URL(string: urlStr) else {
                throw ImageGenError(message: "No image URL in fal.ai result")
            }
            let (imageData, _) = try await URLSession.shared.data(from: imageURL)
            return try decode(imageData)
        }
        throw ImageGenError(message: "fal.ai request timed out after 60s")
    }

    // MARK: - GPT Image (gpt-image-2.5-sunburst and gpt-image-2.5-flare)
    // Both return b64_json; we request 1536×1024 landscape and upscale to 4K.

    private func gptImageGen(prompt: String, apiKey: String, model: String, quality: String) async throws -> (jpeg: Data, image: NSImage) {
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
            "quality":            quality,
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
