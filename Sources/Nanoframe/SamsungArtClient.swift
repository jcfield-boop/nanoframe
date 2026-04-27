import Foundation
import Network

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

    /// TCP preflight — fails fast (3 s) before the WebSocket handshake.
    func checkReachable() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            guard let port = NWEndpoint.Port(rawValue: 8001) else {
                cont.resume(throwing: ArtError.invalidURL); return
            }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            var resolved = false
            conn.stateUpdateHandler = { state in
                guard !resolved else { return }
                switch state {
                case .ready:
                    resolved = true; conn.cancel(); cont.resume()
                case .failed, .cancelled:
                    resolved = true; conn.cancel()
                    cont.resume(throwing: ArtError.tvUnreachable)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                guard !resolved else { return }
                resolved = true; conn.cancel()
                cont.resume(throwing: ArtError.tvUnreachable)
            }
        }
    }

    func connect() async throws {
        let appName = Data("Nanoframe".utf8).base64EncodedString()
        var comps = URLComponents()
        comps.scheme  = "ws"
        comps.host    = host
        comps.port    = 8001
        comps.path    = "/api/v2/channels/com.samsung.art-app"
        comps.queryItems = [URLQueryItem(name: "name", value: appName)]
        if !token.isEmpty {
            comps.queryItems?.append(URLQueryItem(name: "token", value: token))
        }
        guard let url = comps.url else { throw ArtError.invalidURL }

        urlSession   = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        // Wait for ms.channel.connect — contains our assigned clientId and token
        let raw = try await receiveRaw(timeout: 10)
        if let d    = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let info = json["data"] as? [String: Any] {
            token    = info["token"] as? String ?? token
            clientId = info["id"]    as? String ?? clientId
        }
        onRawMessage?("→ connected: clientId=\(clientId)")

        // Drain ms.channel.ready (arrives ~1 s after connect; must be consumed before sending)
        _ = try? await receiveRaw(timeout: 3)
    }

    func uploadAndDisplay(_ jpegData: Data) async throws -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"

        // send_image: request an upload slot.
        // Both "id" and "request_id" MUST be present and equal — newer firmware silently
        // ignores requests that are missing request_id (discovered via samsungtvws library).
        // conn_info.id must also match.
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
                "id":            clientId       // must equal outer id / request_id
            ] as [String: Any]
        ] as [String: Any])

        // Wait for "ready_to_use" — TV tells us which TCP port to upload to
        onProgress?("Waiting for TV upload port…")
        let (port, secKey) = try await waitForReadyToUse(timeout: 20)

        onProgress?("Uploading image via TCP…")
        try await tcpUpload(jpegData, port: port, secKey: secKey)

        // Wait for "image_added" — TV confirms it received and stored the image
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

    /// Resume Samsung Art rotation, optionally deleting specific tracked uploads.
    ///
    /// - Parameter deleteIds: Nanoframe-uploaded content IDs to remove. Pass [] to keep them
    ///   in My Photos as a gallery — the rotation still resumes by selecting a SAM-* piece.
    func revertToSamsungArt(deleteIds: [String]) async throws {
        // ── Step 1: fetch content list to find a SAM-* Art Store item ────────
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

        // Pick the first Samsung Art Store item (SAM-* in MY-C0004) to display on resume
        let resumeId = allItems.first {
            ($0["content_id"] as? String)?.hasPrefix("SAM-") == true &&
            ($0["category_id"] as? String) == "MY-C0004"
        }?["content_id"] as? String

        onRawMessage?("→ revert: delete \(deleteIds.count) IDs, resume with \(resumeId ?? "none")")

        // ── Step 2: delete tracked Nanoframe uploads (if requested) ──────────
        if !deleteIds.isEmpty,
           let listData = try? JSONSerialization.data(withJSONObject: deleteIds),
           let listStr  = String(data: listData, encoding: .utf8) {
            try await sendArtRequest([
                "request":         "delete_image_list",
                "content_id_list": listStr
            ] as [String: Any])
            _ = try? await waitForEvent("image_list_deleted", timeout: 10)
        }

        // ── Step 3: select a SAM-* item to restart the Art Store rotation ────
        if let resumeId {
            try await sendArtRequest([
                "request":    "select_image",
                "content_id": resumeId,
                "show":       true
            ] as [String: Any])
        } else {
            try? await sendArtRequest([
                "request": "set_artmode_status",
                "value":   "on"
            ] as [String: Any])
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: - WebSocket helpers

    /// Wrap an art request in the standard ms.channel.emit envelope and send it.
    /// Automatically injects "id" and "request_id" (must match; newer firmware requires both).
    private func sendArtRequest(_ params: [String: Any]) async throws {
        var p = params
        p["id"]         = clientId
        p["request_id"] = clientId   // ← critical: newer firmware requires request_id == id

        let inner    = try JSONSerialization.data(withJSONObject: p)
        let innerStr = String(data: inner, encoding: .utf8) ?? "{}"

        let msg: [String: Any] = [
            "method": "ms.channel.emit",
            "params": [
                "event": "art_app_request",
                "to":    "host",
                "data":  innerStr
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: msg)
        guard let str = String(data: data, encoding: .utf8) else { return }
        print("[TX] \(str)")
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
            // Also write to /tmp for easy inspection
            let line = "[TV \(Date())] \(result)\n"
            print(line, terminator: "")
            if let data = line.data(using: .utf8),
               let fh = FileHandle(forWritingAtPath: "/tmp/nanoframe_tv.log") {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: "/tmp/nanoframe_tv.log",
                                               contents: line.data(using: .utf8))
            }
            return result
        }
    }

    /// Poll until we receive an art event that has `key` in its payload.
    private func waitForKey(_ key: String, timeout: TimeInterval) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.05 else { throw ArtError.timeout }
            let raw = try await receiveRaw(timeout: remaining)
            guard let parsed = parseArtEvent(raw) else { continue }
            try checkForTVError(parsed)
            if parsed[key] != nil { return parsed }
        }
        throw ArtError.timeout
    }

    /// Poll until we receive an art event whose "event" field equals `eventName`.
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

    /// Waits for "ready_to_use" and extracts the TCP port + secKey from conn_info.
    /// conn_info may arrive as a JSON-string or as an already-decoded dict.
    private func waitForReadyToUse(timeout: TimeInterval) async throws -> (port: Int, secKey: String) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.05 else { throw ArtError.timeout }
            let raw = try await receiveRaw(timeout: remaining)
            guard let parsed = parseArtEvent(raw) else { continue }
            try checkForTVError(parsed)
            guard parsed["event"] as? String == "ready_to_use" else { continue }

            // conn_info can arrive as a JSON string (double-encoded) or as a dict
            let connInfo: [String: Any]?
            if let str  = parsed["conn_info"] as? String,
               let data = str.data(using: .utf8),
               let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                connInfo = obj
            } else {
                connInfo = parsed["conn_info"] as? [String: Any]
            }

            guard let info = connInfo else {
                throw ArtError.noUploadPort
            }

            // port arrives as a String in the TV response
            let portStr = info["port"] as? String ?? "\(info["port"] ?? "")"
            guard let port = Int(portStr), port > 0 else { throw ArtError.noUploadPort }
            let secKey = info["key"] as? String ?? ""
            onRawMessage?("→ ready_to_use: port=\(port) key=\(secKey.prefix(8))…")
            return (port, secKey)
        }
        throw ArtError.timeout
    }

    /// Parses any Samsung art event frame down to its inner data dictionary.
    private func parseArtEvent(_ raw: String) -> [String: Any]? {
        guard let d    = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }

        // Primary path: {"method":"ms.channel.emit","params":{"event":"d2d_service_message","data":"{...}"}}
        if let params = json["params"] as? [String: Any] {
            if let str   = params["data"] as? String,
               let inner = try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [String: Any] {
                return inner
            }
            if let obj = params["data"] as? [String: Any] { return obj }
        }
        // Fallback: top-level "data" field (connect / ready events)
        if let str   = json["data"] as? String,
           let inner = try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [String: Any] {
            return inner
        }
        if let obj = json["data"] as? [String: Any] { return obj }
        return json
    }

    /// If the parsed event is an error frame, throw a descriptive error.
    private func checkForTVError(_ parsed: [String: Any]) throws {
        if parsed["event"] as? String == "error" {
            let code = parsed["error_code"] as? String
                    ?? "\(parsed["error_code"] ?? "unknown")"
            throw ArtError.tvError(code)
        }
    }

    // MARK: - TCP image upload
    //
    // Samsung Frame TV upload wire format:
    //   [4 bytes big-endian: length of JSON header]
    //   [JSON header bytes]
    //   [raw JPEG bytes]
    //
    // JSON header keys: num, total, fileLength, fileName, fileType, secKey, version

    private func tcpUpload(_ data: Data, port: Int, secKey: String) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ArtError.noUploadPort
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

        // Wait for TCP connection to be ready
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resolved = false
            conn.stateUpdateHandler = { state in
                guard !resolved else { return }
                if case .ready = state {
                    resolved = true; cont.resume()
                }
                if case .failed(let e) = state {
                    resolved = true; cont.resume(throwing: ArtError.uploadFailed(e.localizedDescription))
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        // Build and send the length-prefixed JSON header
        let header: [String: Any] = [
            "num":        0,
            "total":      1,
            "fileLength": data.count,
            "fileName":   "dummy",
            "fileType":   "jpg",
            "secKey":     secKey,
            "version":    "0.0.1"
        ]
        guard let headerJSON = try? JSONSerialization.data(withJSONObject: header) else {
            throw ArtError.uploadFailed("Could not build upload header")
        }
        var lenBE = UInt32(headerJSON.count).bigEndian
        var prefix = Data(bytes: &lenBE, count: 4)
        prefix.append(headerJSON)
        onRawMessage?("→ TCP header: \(String(data: headerJSON, encoding: .utf8) ?? "")")
        try await tcpSend(conn, content: prefix)

        // Stream JPEG in 64 KB chunks, reporting progress
        let chunkSize = 65_536
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            try await tcpSend(conn, content: data[offset..<end])
            offset = end
            onUploadProgress?(Double(offset) / Double(data.count))
        }

        conn.cancel()
        onRawMessage?("→ TCP upload complete (\(data.count) bytes)")
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

// MARK: - TLS delegate (accepts TV's self-signed cert for wss://)

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
