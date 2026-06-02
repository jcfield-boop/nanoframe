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

    /// Whether this provider's API can accept a source image for guided generation.
    var supportsSourcePhoto: Bool {
        switch self {
        case .gptImage1, .gptImage1Mini: return true
        case .pollinations, .nanoBanana:  return false
        }
    }

    /// Human-readable reason shown in the UI when supportsSourcePhoto == false.
    var sourcePhotoUnavailableReason: String {
        switch self {
        case .gptImage1, .gptImage1Mini: return ""
        case .pollinations: return "Pollinations uses a URL-based API that can't receive image uploads."
        case .nanoBanana:   return "Nano Banana's API doesn't accept source images."
        }
    }
}

struct DallEService {

    // MARK: - Public

    func generate(
        prompt: String,
        apiKey: String,
        provider: ImageProvider,
        sourcePhoto: UIImage? = nil
    ) async throws -> (jpeg: Data, image: UIImage) {
        let enhanced = Self.enhanceForFrameTV(prompt)
        switch provider {
        case .pollinations:
            return try await pollinations(prompt: enhanced)
        case .nanoBanana:
            return try await nanoBanana(prompt: enhanced, apiKey: apiKey)
        case .gptImage1:
            if let photo = sourcePhoto {
                return try await gptImageEdit(prompt: enhanced, apiKey: apiKey,
                                              model: "gpt-image-1", source: photo)
            }
            return try await gptImageGen(prompt: enhanced, apiKey: apiKey, model: "gpt-image-1")
        case .gptImage1Mini:
            if let photo = sourcePhoto {
                return try await gptImageEdit(prompt: enhanced, apiKey: apiKey,
                                              model: "gpt-image-1-mini", source: photo)
            }
            return try await gptImageGen(prompt: enhanced, apiKey: apiKey, model: "gpt-image-1-mini")
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
        guard src.width < 3000 else { return jpegData }

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

    // MARK: - GPT Image — text-to-image (generations endpoint)
    // Both models return b64_json and support 1536×1024 landscape.

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

    // MARK: - GPT Image — image-to-image (edits endpoint)
    // Sends the source photo as multipart form-data; the model repaints it according to the prompt.

    private func gptImageEdit(prompt: String, apiKey: String, model: String,
                               source: UIImage) async throws -> (jpeg: Data, image: UIImage) {
        guard let imageData = prepareSourceImage(source) else {
            throw ImageGenError(message: "Could not prepare source image for upload")
        }

        let url = URL(string: "https://api.openai.com/v1/images/edits")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        req.httpBody = makeMultipart(
            boundary: boundary,
            fields: [
                (name: "model",   value: model),
                (name: "prompt",  value: prompt),
                (name: "n",       value: "1"),
                (name: "size",    value: "1536x1024"),
                (name: "quality", value: model.hasSuffix("mini") ? "medium" : "high")
            ],
            fileField: "image",
            filename:  "source.jpg",
            mimeType:  "image/jpeg",
            fileData:  imageData
        )

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkHTTP(response, data: data)

        struct Resp: Decodable { struct Item: Decodable { let b64_json: String }; let data: [Item] }
        let result = try JSONDecoder().decode(Resp.self, from: data)
        guard let b64 = result.data.first?.b64_json,
              let decoded = Data(base64Encoded: b64) else {
            throw ImageGenError(message: "No image data in \(model) edit response")
        }
        return try decode(decoded)
    }

    // MARK: - Image helpers

    /// Resizes a UIImage so the longest edge is ≤ maxDimension, then encodes as JPEG.
    /// Handles HEIC natively — UIGraphicsImageRenderer normalises orientation and format.
    private func prepareSourceImage(_ image: UIImage, maxDimension: CGFloat = 1536) -> Data? {
        let size    = image.size
        let longest = max(size.width, size.height)
        let scale   = longest > maxDimension ? maxDimension / longest : 1
        let target  = CGSize(width:  (size.width  * scale).rounded(),
                             height: (size.height * scale).rounded())

        let renderer = UIGraphicsImageRenderer(size: target)
        let resized  = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.92)
    }

    /// Builds a multipart/form-data body manually — Foundation has no built-in encoder.
    private func makeMultipart(boundary: String,
                               fields: [(name: String, value: String)],
                               fileField: String, filename: String,
                               mimeType: String, fileData: Data) -> Data {
        var body = Data()

        func append(_ s: String) { body.append(Data(s.utf8)) }

        for field in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            append("\(field.value)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        return body
    }

    // MARK: - HTTP helpers

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
