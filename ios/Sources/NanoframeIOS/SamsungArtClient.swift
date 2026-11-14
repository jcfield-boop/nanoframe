import Foundation
import Network
import Security

/// One-shot gate so an NWConnection continuation is resumed exactly once.
private final class D2DGate: @unchecked Sendable {
    private var fired = false
    private let lock  = NSLock()
    func fire(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        body()
    }
}

/// Thread-safe one-shot gate: the first caller to `fire` wins; subsequent calls are no-ops.
/// Used in NWConnection state handlers to ensure a CheckedContinuation is resumed exactly once.
private final class Once: @unchecked Sendable {
    private var fired = false
    private let lock  = NSLock()
    func fire(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        body()
    }
}

enum ArtError: LocalizedError {
    case invalidURL
    case tvUnreachable
    case noResponse
    case noUploadPort
    case timeout
    case tvError(String)
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:          return "Invalid TV address"
        case .tvUnreachable:       return "TV is unreachable — make sure it's on and try again"
        case .noResponse:          return "TV connected but didn't respond"
        case .noUploadPort:        return "TV didn't provide an upload port — make sure it's in Art/Frame Mode"
        case .timeout:             return "Timed out waiting for TV response"
        case .tvError(let m):      return "TV error: \(m)"
        case .uploadFailed(let m): return "Upload failed: \(m)"
        }
    }
}

// MARK: - Client

class SamsungArtClient: NSObject {
    let host: String
    private(set) var token: String
    private var clientId: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let delegate = TrustAllDelegate()

    var onProgress: ((String) -> Void)?
    var onUploadProgress: ((Double) -> Void)?
    var onRawMessage: ((String) -> Void)?

    init(host: String, savedToken: String = "") {
        self.host = host
        self.token = savedToken
        self.clientId = UUID().uuidString
    }

    // MARK: - Public API

    func checkReachable() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            guard let port = NWEndpoint.Port(rawValue: 8001) else {
                cont.resume(throwing: ArtError.invalidURL); return
            }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.fire { conn.cancel(); cont.resume() }
                case .failed, .cancelled:
                    once.fire { conn.cancel(); cont.resume(throwing: ArtError.tvUnreachable) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                once.fire { conn.cancel(); cont.resume(throwing: ArtError.tvUnreachable) }
            }
        }
    }

    /// 2022+ Frame TVs (including 2026 models) only expose the art-mode channel on the
    /// encrypted port 8002 (wss); pre-2022 sets (e.g. the LS03A this was originally built
    /// against) only have the plaintext channel on 8001. Try the modern port first and
    /// fall back, since plain port-8001 reachability (used by discovery) doesn't tell us
    /// which channel the TV's firmware actually serves.
    private static let connectAttempts: [(scheme: String, port: Int)] = [("wss", 8002), ("ws", 8001)]

    func connect() async throws {
        let appName = Data("Nanoframe".utf8).base64EncodedString()

        func buildURL(scheme: String, port: Int) -> URL? {
            var comps = URLComponents()
            comps.scheme = scheme
            comps.host   = host
            comps.port   = port
            comps.path   = "/api/v2/channels/com.samsung.art-app"
            comps.queryItems = [URLQueryItem(name: "name", value: appName)]
            if !token.isEmpty {
                comps.queryItems?.append(URLQueryItem(name: "token", value: token))
            }
            return comps.url
        }

        var lastError: Error = ArtError.tvUnreachable
        for attempt in Self.connectAttempts {
            guard let url = buildURL(scheme: attempt.scheme, port: attempt.port) else { continue }

            urlSession    = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            webSocketTask = urlSession?.webSocketTask(with: url)
            webSocketTask?.resume()

            do {
                let raw = try await receiveRaw(timeout: 10)
                if let d    = raw.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let info = json["data"] as? [String: Any] {
                    token    = info["token"] as? String ?? token
                    clientId = info["id"]    as? String ?? clientId
                }
                onRawMessage?("→ connected via \(attempt.scheme):\(attempt.port), clientId=\(clientId)")
                _ = try? await receiveRaw(timeout: 3)
                return
            } catch {
                lastError = error
                webSocketTask?.cancel(with: .goingAway, reason: nil)
                webSocketTask = nil
            }
        }
        throw lastError
    }

    func uploadAndDisplay(_ jpegData: Data) async throws -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"

        onProgress?("Requesting upload slot…")
        try await sendArtRequest([
            "request":           "send_image",
            "file_type":         "JPEG",
            "file_size":         jpegData.count,
            "image_date":        fmt.string(from: Date()),
            "matte_id":          "none",
            "portrait_matte_id": "shadowbox_polar",
            "conn_info": [
                "d2d_mode":      "socket",
                "connection_id": Int.random(in: 100_000...999_999),
                "id":            clientId
            ] as [String: Any]
        ] as [String: Any])

        onProgress?("Waiting for TV upload port…")
        let slot = try await waitForReadyToUse(timeout: 20)

        onProgress?("Uploading image via TCP…")
        try await tcpUpload(jpegData, port: slot.port, secKey: slot.secKey,
                            secured: slot.secured, ip: slot.ip)

        onProgress?("Waiting for TV to process image…")
        guard let idResp = try? await waitForEvent("image_added", timeout: 30) else {
            throw ArtError.timeout
        }
        let contentId = idResp["content_id"] as? String ?? ""

        if !contentId.isEmpty {
            onProgress?("Selecting image on display…")
            try await sendArtRequest([
                "request":    "select_image",
                "content_id": contentId,
                "show":       true
            ] as [String: Any])
        }

        disconnect()
        return contentId
    }

    /// Re-display an image that is already stored on the TV (no upload needed).
    func selectExisting(_ contentId: String) async throws {
        try await sendArtRequest([
            "request":    "select_image",
            "content_id": contentId,
            "show":       true
        ] as [String: Any])
        disconnect()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    func revertToSamsungArt(deleteIds: [String]) async throws {
        try await sendArtRequest([
            "request":     "get_content_list",
            "category_id": "MY-C0002"
        ] as [String: Any])

        let listEvent = try? await waitForEvent("content_list", timeout: 8)

        var allItems: [[String: Any]] = []
        if let event = listEvent {
            let raw = event["content_list"]
            if let arr = raw as? [[String: Any]] {
                allItems = arr
            } else if let str = raw as? String,
                      let data = str.data(using: .utf8),
                      let arr  = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                allItems = arr
            }
        }

        let resumeId = allItems.first {
            ($0["content_id"] as? String)?.hasPrefix("SAM-") == true &&
            ($0["category_id"] as? String) == "MY-C0004"
        }?["content_id"] as? String

        onRawMessage?("→ revert: delete \(deleteIds.count) IDs, resume with \(resumeId ?? "none")")

        if !deleteIds.isEmpty,
           let listData = try? JSONSerialization.data(withJSONObject: deleteIds),
           let listStr  = String(data: listData, encoding: .utf8) {
            try await sendArtRequest([
                "request":         "delete_image_list",
                "content_id_list": listStr
            ] as [String: Any])
            _ = try? await waitForEvent("image_list_deleted", timeout: 10)
        }

        if let resumeId {
            try await sendArtRequest([
                "request":    "select_image",
                "content_id": resumeId,
                "show":       true
            ] as [String: Any])
        } else {
            try? await sendArtRequest(["request": "set_artmode_status", "value": "on"] as [String: Any])
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: - WebSocket helpers

    private func sendArtRequest(_ params: [String: Any]) async throws {
        var p = params
        p["id"]         = clientId
        p["request_id"] = clientId

        let inner    = try JSONSerialization.data(withJSONObject: p)
        let innerStr = String(data: inner, encoding: .utf8) ?? "{}"
        let msg: [String: Any] = [
            "method": "ms.channel.emit",
            "params": ["event": "art_app_request", "to": "host", "data": innerStr]
        ]
        let data = try JSONSerialization.data(withJSONObject: msg)
        guard let str = String(data: data, encoding: .utf8) else { return }
        onRawMessage?("→ SEND: \(innerStr)")
        try await webSocketTask?.send(.string(str))
    }

    private func receiveRaw(timeout: TimeInterval) async throws -> String {
        guard let task = webSocketTask else { throw ArtError.noResponse }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                switch try await task.receive() {
                case .string(let s): return s
                case .data(let d):   return String(data: d, encoding: .utf8) ?? "<binary \(d.count)b>"
                @unknown default:    return ""
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ArtError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            onRawMessage?(result)
            return result
        }
    }

    private func waitForEvent(_ eventName: String, timeout: TimeInterval) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.05 else { throw ArtError.timeout }
            let raw = try await receiveRaw(timeout: remaining)
            guard let parsed = parseArtEvent(raw) else { continue }
            try checkForTVError(parsed)
            if parsed["event"] as? String == eventName { return parsed }
        }
        throw ArtError.timeout
    }

    private func waitForReadyToUse(timeout: TimeInterval) async throws
        -> (port: Int, secKey: String, secured: Bool, ip: String?) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.05 else { throw ArtError.timeout }
            let raw = try await receiveRaw(timeout: remaining)
            guard let parsed = parseArtEvent(raw) else { continue }
            try checkForTVError(parsed)
            guard parsed["event"] as? String == "ready_to_use" else { continue }

            let connInfo: [String: Any]?
            if let str  = parsed["conn_info"] as? String,
               let data = str.data(using: .utf8),
               let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                connInfo = obj
            } else {
                connInfo = parsed["conn_info"] as? [String: Any]
            }
            guard let info = connInfo else { throw ArtError.noUploadPort }

            let portStr = info["port"] as? String ?? "\(info["port"] ?? "")"
            guard let port = Int(portStr), port > 0 else { throw ArtError.noUploadPort }
            let secKey = info["key"] as? String ?? ""
            // "secured" arrives as a JSON bool on current firmware; tolerate "true"/1 too.
            let secured: Bool
            switch info["secured"] {
            case let b as Bool:   secured = b
            case let s as String: secured = (s as NSString).boolValue
            case let n as NSNumber: secured = n.boolValue
            default:              secured = false
            }
            let ip = info["ip"] as? String
            onRawMessage?("→ ready_to_use: ip=\(ip ?? host) port=\(port) secured=\(secured) key=\(secKey.prefix(8))…")
            return (port, secKey, secured, ip)
        }
        throw ArtError.timeout
    }

    private func parseArtEvent(_ raw: String) -> [String: Any]? {
        guard let d    = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        if let params = json["params"] as? [String: Any] {
            if let str   = params["data"] as? String,
               let inner = try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [String: Any] { return inner }
            if let obj = params["data"] as? [String: Any] { return obj }
        }
        if let str   = json["data"] as? String,
           let inner = try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [String: Any] { return inner }
        if let obj = json["data"] as? [String: Any] { return obj }
        return json
    }

    private func checkForTVError(_ parsed: [String: Any]) throws {
        if parsed["event"] as? String == "error" {
            let code = parsed["error_code"] as? String ?? "\(parsed["error_code"] ?? "unknown")"
            throw ArtError.tvError(code)
        }
    }

    // MARK: - TCP image upload

    private func tcpUpload(_ data: Data, port: Int, secKey: String,
                           secured: Bool, ip: String?) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ArtError.noUploadPort
        }
        // Connect to the address the TV handed back in ready_to_use (falls back to the
        // configured host). Since 2024-era Frame firmware the d2d socket reports
        // "secured": true and expects TLS; a plain TCP stream is accepted at the TCP
        // level but the TV never reads the image, so no image_added ever arrives.
        let targetHost = (ip?.isEmpty == false) ? ip! : host
        let conn = NWConnection(host: NWEndpoint.Host(targetHost), port: nwPort,
                                using: Self.d2dParameters(secured: secured))
        onRawMessage?("→ d2d connect \(targetHost):\(port) \(secured ? "TLS" : "plain TCP")")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = D2DGate()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.fire { cont.resume() }
                case .failed(let e), .waiting(let e):
                    gate.fire { conn.cancel(); cont.resume(throwing: ArtError.uploadFailed(e.localizedDescription)) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                gate.fire { conn.cancel(); cont.resume(throwing: ArtError.uploadFailed("d2d connect timed out")) }
            }
        }

        let header: [String: Any] = [
            "num":        0,
            "total":      1,
            "fileLength": data.count,
            "fileName":   "image",
            "fileType":   "jpg",
            "secKey":     secKey,
            "version":    "0.0.1"
        ]
        guard let headerJSON = try? JSONSerialization.data(withJSONObject: header) else {
            conn.cancel()
            throw ArtError.uploadFailed("Could not build upload header")
        }
        var lenBE = UInt32(headerJSON.count).bigEndian
        var prefix = Data(bytes: &lenBE, count: 4)
        prefix.append(headerJSON)
        onRawMessage?("→ TCP header: \(String(data: headerJSON, encoding: .utf8) ?? "")")

        do {
            try await tcpSend(conn, content: prefix)
            let chunkSize = 65_536
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                try await tcpSend(conn, content: data.subdata(in: offset..<end))
                offset = end
                onUploadProgress?(Double(offset) / Double(data.count))
            }
        } catch {
            conn.cancel()
            throw error
        }
        conn.cancel()   // graceful: flushes, then TLS close_notify / FIN
        onRawMessage?("→ TCP upload complete (\(data.count) bytes)")
    }

    /// Plain TCP, or TLS that accepts the TV's self-signed certificate.
    private static func d2dParameters(secured: Bool) -> NWParameters {
        guard secured else { return .tcp }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, .global())
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    private func tcpSend(_ conn: NWConnection, content: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: content, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: ArtError.uploadFailed(err.localizedDescription)) }
                else       { cont.resume() }
            })
        }
    }
}

// MARK: - TLS delegate

private class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
