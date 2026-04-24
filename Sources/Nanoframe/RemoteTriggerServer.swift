import Foundation

/// Listens on 0.0.0.0:11436 (IPv4) for POST /generate {"prompt":"..."}
/// Used by the Lango ESP32 tool_frame_tv to trigger generation remotely.
///
/// NWListener creates an IPv6-only socket on macOS, which the ESP32 (IPv4) cannot reach.
/// This implementation uses plain POSIX sockets so it binds explicitly to INADDR_ANY (IPv4).
class RemoteTriggerServer {
    static let port: UInt16 = 11436
    private var serverFD: Int32 = -1
    private var running = false
    private let onPrompt: (String) -> Void

    init(onPrompt: @escaping (String) -> Void) {
        self.onPrompt = onPrompt
    }

    func start() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("⚠️  RemoteTriggerServer: socket() failed — errno \(errno)")
            return
        }

        // Allow immediate re-bind after restart
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = Self.port.bigEndian
        addr.sin_addr   = in_addr(s_addr: INADDR_ANY)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            print("⚠️  RemoteTriggerServer: bind() failed — port \(Self.port) may be in use (errno \(errno))")
            return
        }

        guard listen(fd, 8) == 0 else {
            close(fd)
            print("⚠️  RemoteTriggerServer: listen() failed — errno \(errno)")
            return
        }

        serverFD = fd
        running  = true
        print("✅  RemoteTriggerServer listening on 0.0.0.0:\(Self.port) (IPv4)")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        running = false
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while running && serverFD >= 0 {
            var clientAddr = sockaddr_in()
            var addrLen    = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD   = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFD, $0, &addrLen)
                }
            }
            guard clientFD >= 0 else { break }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handle(clientFD)
            }
        }
    }

    // MARK: - Request handler

    private func handle(_ fd: Int32) {
        defer { close(fd) }

        // Read the complete HTTP request.
        // esp_http_client (ESP-IDF) may send headers and body in separate TCP writes,
        // so we loop until we have all header bytes + the declared Content-Length body.
        var raw = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)

        var headerEndIdx: Int? = nil   // byte offset just past \r\n\r\n
        var contentLength: Int  = 0

        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { break }
            raw.append(contentsOf: chunk.prefix(n))

            // Find end of headers once
            if headerEndIdx == nil,
               let range = raw.range(of: Data("\r\n\r\n".utf8)) {
                headerEndIdx = range.upperBound
                // Parse Content-Length from headers
                let headerStr = String(data: raw.prefix(range.lowerBound), encoding: .utf8) ?? ""
                for line in headerStr.components(separatedBy: "\r\n") {
                    if line.lowercased().hasPrefix("content-length:") {
                        contentLength = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
            }

            // Stop once body is fully received
            if let end = headerEndIdx, raw.count >= end + contentLength { break }
        }

        guard let headerEnd = headerEndIdx else { return }
        let body = String(data: raw.suffix(from: headerEnd), encoding: .utf8) ?? ""

        // Log raw request for debugging
        print("[TriggerServer] body: \(body.prefix(200))")

        if let jd     = body.data(using: .utf8),
           let json   = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
           let prompt = json["prompt"] as? String, !prompt.isEmpty {
            send(fd, response: "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}")
            onPrompt(prompt)
        } else {
            print("[TriggerServer] 400 — body not valid JSON with 'prompt' key")
            send(fd, response: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
        }
    }

    private func send(_ fd: Int32, response: String) {
        let bytes = Array(response.utf8)
        _ = Foundation.send(fd, bytes, bytes.count, 0)
    }
}
