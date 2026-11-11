import Foundation
import Network

struct DiscoveredTV: Identifiable, Equatable {
    let id = UUID()
    let ip: String
    let name: String
}

/// Finds Samsung Frame TVs on the current LAN without needing a hardcoded IP.
///
/// Frame TVs don't advertise over mDNS/Bonjour, so this sweeps the local /24
/// subnet for hosts with the Samsung Smart TV port (8001) open, then confirms
/// each one via the TV's own REST info endpoint. This also means tv_ip keeps
/// working across router/DHCP renumbering (the LAN here has moved from
/// 192.168.0.x to 192.168.68.x before) since the subnet is derived from this
/// device's own current IP rather than assumed.
enum FrameTVDiscovery {
    static func scan(timeout: TimeInterval = 0.6) async -> [DiscoveredTV] {
        guard let localIP = localIPv4(), let prefix = subnetPrefix(of: localIP) else { return [] }
        let candidates = (1...254).map { "\(prefix).\($0)" }

        let liveHosts = await withTaskGroup(of: String?.self) { group in
            for ip in candidates {
                group.addTask { await probePort8001(ip, timeout: timeout) ? ip : nil }
            }
            var results: [String] = []
            for await host in group where host != nil { results.append(host!) }
            return results
        }

        return await withTaskGroup(of: DiscoveredTV?.self) { group in
            for ip in liveHosts {
                group.addTask { await fetchDeviceInfo(ip) }
            }
            var results: [DiscoveredTV] = []
            for await tv in group where tv != nil { results.append(tv!) }
            return results.sorted { $0.ip < $1.ip }
        }
    }

    // MARK: - Probing

    private static func probePort8001(_ ip: String, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            guard let port = NWEndpoint.Port(rawValue: 8001) else { cont.resume(returning: false); return }
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: port, using: .tcp)
            var resolved = false
            let finish: (Bool) -> Void = { ok in
                guard !resolved else { return }
                resolved = true
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:              finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private static func fetchDeviceInfo(_ ip: String) async -> DiscoveredTV? {
        guard let url = URL(string: "http://\(ip):8001/api/v2/") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let device = json["device"] as? [String: Any] else { return nil }
            let frameSupport = (device["FrameTVSupport"] as? String)?.lowercased() == "true"
            let isSamsung = (device["type"] as? String)?.localizedCaseInsensitiveContains("Samsung") == true
            guard frameSupport || isSamsung else { return nil }
            let name = (device["name"] as? String).flatMap { $0.removingPercentEncoding } ?? "Samsung TV"
            return DiscoveredTV(ip: ip, name: name)
        } catch {
            return nil
        }
    }

    // MARK: - Local subnet

    private static func subnetPrefix(of ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }

    private static func localIPv4() -> String? {
        var address: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let interface = p.pointee
            guard let ifaAddr = interface.ifa_addr, ifaAddr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue } // Wi-Fi/Ethernet on both macOS and iOS

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifaAddr, socklen_t(ifaAddr.pointee.sa_len),
                        &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostBuffer)
            if ip != "127.0.0.1" { address = ip; break }
        }
        return address
    }
}
