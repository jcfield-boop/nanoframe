/// Samsung Frame TV Art Protocol — unit validation
/// Tests every layer of the wire format before it touches a real TV.
///
/// Run with:  swift run ProtocolTests

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Mini test harness
// ─────────────────────────────────────────────────────────────────────────────

var passed = 0
var failed = 0

func test(_ name: String, _ block: () throws -> Void) {
    do {
        try block()
        print("  ✅  \(name)")
        passed += 1
    } catch {
        print("  ❌  \(name): \(error)")
        failed += 1
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "") throws {
    guard a == b else {
        throw NSError(domain: "assert", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "Expected \(b), got \(a)\(msg.isEmpty ? "" : " — \(msg)")"])
    }
}

func assertNotNil<T>(_ v: T?, _ msg: String = "") throws {
    guard v != nil else {
        throw NSError(domain: "assert", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "Expected non-nil\(msg.isEmpty ? "" : " — \(msg)")"])
    }
}

func assertNil<T>(_ v: T?, _ msg: String = "") throws {
    guard v == nil else {
        throw NSError(domain: "assert", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "Expected nil, got \(v!)\(msg.isEmpty ? "" : " — \(msg)")"])
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Protocol helpers  (mirrors SamsungArtClient internals)
// ─────────────────────────────────────────────────────────────────────────────

let testClientId = "12345678-abcd-4abc-8abc-123456789012"   // example client ID

/// Builds the full WebSocket frame for an art request (mirrors sendArtRequest).
func buildArtRequest(_ params: [String: Any], clientId: String) throws -> (outerStr: String, innerDict: [String: Any]) {
    var p = params
    p["id"]         = clientId
    p["request_id"] = clientId

    let innerData = try JSONSerialization.data(withJSONObject: p)
    let innerStr  = String(data: innerData, encoding: .utf8)!

    let msg: [String: Any] = [
        "method": "ms.channel.emit",
        "params": [
            "event": "art_app_request",
            "to":    "host",
            "data":  innerStr
        ]
    ]
    let outerData = try JSONSerialization.data(withJSONObject: msg)
    let outerStr  = String(data: outerData, encoding: .utf8)!

    let innerDict = try JSONSerialization.jsonObject(with: innerData) as! [String: Any]
    return (outerStr, innerDict)
}

/// Parses any Samsung art event frame down to its inner data dictionary.
func parseArtEvent(_ raw: String) -> [String: Any]? {
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

/// Extracts (port, secKey) from a parsed ready_to_use payload.
func extractConnInfo(_ parsed: [String: Any]) throws -> (port: Int, secKey: String) {
    let connInfo: [String: Any]?
    if let str  = parsed["conn_info"] as? String,
       let data = str.data(using: .utf8),
       let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        connInfo = obj
    } else {
        connInfo = parsed["conn_info"] as? [String: Any]
    }
    guard let info = connInfo else {
        throw NSError(domain: "proto", code: 1, userInfo: [NSLocalizedDescriptionKey: "no conn_info"])
    }
    let portStr = info["port"] as? String ?? "\(info["port"] ?? "")"
    guard let port = Int(portStr), port > 0 else {
        throw NSError(domain: "proto", code: 2, userInfo: [NSLocalizedDescriptionKey: "bad port"])
    }
    let secKey = info["key"] as? String ?? ""
    return (port, secKey)
}

/// Builds the TCP upload prefix: 4-byte BE length + JSON header bytes.
func buildTCPHeader(fileLength: Int, secKey: String) throws -> Data {
    let header: [String: Any] = [
        "num":        0,
        "total":      1,
        "fileLength": fileLength,
        "fileName":   "dummy",
        "fileType":   "jpg",
        "secKey":     secKey,
        "version":    "0.0.1"
    ]
    let headerJSON = try JSONSerialization.data(withJSONObject: header)
    var lenBE = UInt32(headerJSON.count).bigEndian
    var prefix = Data(bytes: &lenBE, count: 4)
    prefix.append(headerJSON)
    return prefix
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Tests
// ─────────────────────────────────────────────────────────────────────────────

print("\nSamsung Frame TV — Protocol validation\n")

// ── 1. Outer WS envelope ──────────────────────────────────────────────────────
print("1. WebSocket envelope")

test("method is ms.channel.emit") {
    let (outerStr, _) = try buildArtRequest(["request": "get_artmode_status"], clientId: testClientId)
    let json = try JSONSerialization.jsonObject(with: outerStr.data(using: .utf8)!) as! [String: Any]
    try assertEqual(json["method"] as? String, "ms.channel.emit")
}

test("event param is art_app_request") {
    let (outerStr, _) = try buildArtRequest(["request": "get_artmode_status"], clientId: testClientId)
    let json   = try JSONSerialization.jsonObject(with: outerStr.data(using: .utf8)!) as! [String: Any]
    let params = json["params"] as! [String: Any]
    try assertEqual(params["event"] as? String, "art_app_request")
    try assertEqual(params["to"]    as? String, "host")
}

test("data field is a JSON string (not an object)") {
    let (outerStr, _) = try buildArtRequest(["request": "get_artmode_status"], clientId: testClientId)
    let json   = try JSONSerialization.jsonObject(with: outerStr.data(using: .utf8)!) as! [String: Any]
    let params = json["params"] as! [String: Any]
    // data must be a String, not a nested dict
    try assertNotNil(params["data"] as? String, "data should be a String")
    try assertNil(params["data"] as? [String: Any], "data must NOT be a nested dict")
}

// ── 2. Inner request fields ───────────────────────────────────────────────────
print("\n2. Inner request fields")

test("id is injected") {
    let (_, inner) = try buildArtRequest(["request": "get_artmode_status"], clientId: testClientId)
    try assertEqual(inner["id"] as? String, testClientId)
}

test("request_id is injected") {
    let (_, inner) = try buildArtRequest(["request": "get_artmode_status"], clientId: testClientId)
    try assertEqual(inner["request_id"] as? String, testClientId)
}

test("id == request_id (required by newer firmware)") {
    let (_, inner) = try buildArtRequest(["request": "send_image", "file_size": 1234], clientId: testClientId)
    let id  = inner["id"]         as? String
    let rid = inner["request_id"] as? String
    try assertEqual(id, rid, "id and request_id must match")
}

test("send_image conn_info.id matches outer id") {
    let (_, inner) = try buildArtRequest([
        "request":   "send_image",
        "file_size": 12345,
        "conn_info": ["d2d_mode": "socket", "connection_id": 123456, "id": testClientId] as [String: Any]
    ], clientId: testClientId)
    let connInfo = inner["conn_info"] as! [String: Any]
    try assertEqual(connInfo["id"] as? String, inner["id"] as? String,
                    "conn_info.id must equal outer id")
}

test("original request field is preserved") {
    let (_, inner) = try buildArtRequest(["request": "send_image"], clientId: testClientId)
    try assertEqual(inner["request"] as? String, "send_image")
}

// ── 3. Response parsing ───────────────────────────────────────────────────────
print("\n3. Response parsing (parseArtEvent)")

// Real ms.channel.connect format
let connectFrame = """
{"data":{"clients":[{"id":"aecf689f","isHost":true}],"id":"\(testClientId)","token":"12345678"},"event":"ms.channel.connect"}
"""

test("parses ms.channel.connect data dict") {
    let parsed = parseArtEvent(connectFrame)
    try assertNotNil(parsed)
    try assertNotNil(parsed?["id"], "should have id in data")
    try assertEqual(parsed?["id"] as? String, testClientId)
}

// Real d2d_service_message format (artmode_status response)
let artmodeFrame = """
{"method":"ms.channel.emit","params":{"event":"d2d_service_message","to":"client","data":"{\\"event\\":\\"artmode_status\\",\\"value\\":\\"on\\",\\"id\\":\\"\(testClientId)\\"}"}}
"""

test("parses d2d_service_message with JSON-string data") {
    let parsed = parseArtEvent(artmodeFrame)
    try assertNotNil(parsed)
    try assertEqual(parsed?["event"] as? String, "artmode_status")
    try assertEqual(parsed?["value"] as? String, "on")
}

// ready_to_use with conn_info as JSON string (double-encoded).
// Build programmatically to avoid manual triple-escape errors.
let connInfoDict: [String: Any] = ["port": "49152", "key": "abc123sec",
                                   "ip": "192.168.0.24", "d2d_mode": "socket"]
let connInfoStr = String(data: try! JSONSerialization.data(withJSONObject: connInfoDict),
                         encoding: .utf8)!

let readyToUseInnerDict: [String: Any] = ["event": "ready_to_use", "conn_info": connInfoStr]
let readyToUseInnerStr = String(data: try! JSONSerialization.data(withJSONObject: readyToUseInnerDict),
                                encoding: .utf8)!

let readyToUseOuter: [String: Any] = [
    "method": "ms.channel.emit",
    "params": ["event": "d2d_service_message", "to": "client", "data": readyToUseInnerStr] as [String: Any]
]
let readyToUseFrame = String(data: try! JSONSerialization.data(withJSONObject: readyToUseOuter),
                             encoding: .utf8)!

test("parses ready_to_use event") {
    let parsed = parseArtEvent(readyToUseFrame)
    try assertNotNil(parsed)
    try assertEqual(parsed?["event"] as? String, "ready_to_use")
}

test("extracts port from conn_info JSON-string") {
    let parsed = parseArtEvent(readyToUseFrame)!
    let (port, _) = try extractConnInfo(parsed)
    try assertEqual(port, 49152)
}

test("extracts secKey from conn_info JSON-string") {
    let parsed = parseArtEvent(readyToUseFrame)!
    let (_, secKey) = try extractConnInfo(parsed)
    try assertEqual(secKey, "abc123sec")
}

// conn_info as already-decoded dict (alternative firmware format)
let readyToUseDictInnerDict: [String: Any] = [
    "event":     "ready_to_use",
    "conn_info": ["port": "55123", "key": "dictkey", "ip": "192.168.0.24"] as [String: Any]
]
let readyToUseDictInnerStr = String(data: try! JSONSerialization.data(withJSONObject: readyToUseDictInnerDict),
                                    encoding: .utf8)!
let readyToUseDictOuter: [String: Any] = [
    "method": "ms.channel.emit",
    "params": ["event": "d2d_service_message", "to": "client", "data": readyToUseDictInnerStr] as [String: Any]
]
let readyToUseDictFrame = String(data: try! JSONSerialization.data(withJSONObject: readyToUseDictOuter),
                                 encoding: .utf8)!

test("extracts port when conn_info is already a dict") {
    let parsed = parseArtEvent(readyToUseDictFrame)!
    let (port, _) = try extractConnInfo(parsed)
    try assertEqual(port, 55123)
}

// image_added response
let imageAddedInner: [String: Any] = ["event": "image_added", "content_id": "MY_F0042",
                                       "width": "3840", "height": "2160"]
let imageAddedFrame = String(data: try! JSONSerialization.data(withJSONObject: [
    "method": "ms.channel.emit",
    "params": ["event": "d2d_service_message", "to": "client",
               "data": String(data: try! JSONSerialization.data(withJSONObject: imageAddedInner),
                              encoding: .utf8)!] as [String: Any]
] as [String: Any]), encoding: .utf8)!

test("parses image_added with content_id") {
    let parsed = parseArtEvent(imageAddedFrame)!
    try assertEqual(parsed["event"]      as? String, "image_added")
    try assertEqual(parsed["content_id"] as? String, "MY_F0042")
}

// TV error frame
let errorInner: [String: Any] = ["event": "error", "error_code": "301", "request": "send_image"]
let errorFrame = String(data: try! JSONSerialization.data(withJSONObject: [
    "method": "ms.channel.emit",
    "params": ["event": "d2d_service_message", "to": "client",
               "data": String(data: try! JSONSerialization.data(withJSONObject: errorInner),
                              encoding: .utf8)!] as [String: Any]
] as [String: Any]), encoding: .utf8)!

test("parses TV error event") {
    let parsed = parseArtEvent(errorFrame)!
    try assertEqual(parsed["event"]      as? String, "error")
    try assertEqual(parsed["error_code"] as? String, "301")
}

// ── 4. TCP upload header ──────────────────────────────────────────────────────
print("\n4. TCP upload header")

test("prefix is exactly 4 bytes + header") {
    let prefix = try buildTCPHeader(fileLength: 999_999, secKey: "testkey")
    let headerLen = Int(UInt32(bigEndian: prefix[0..<4].withUnsafeBytes { $0.load(as: UInt32.self) }))
    try assertEqual(prefix.count, 4 + headerLen, "prefix length mismatch")
}

test("length prefix is big-endian") {
    let prefix = try buildTCPHeader(fileLength: 1, secKey: "k")
    let headerLen = Int(UInt32(bigEndian: prefix[0..<4].withUnsafeBytes { $0.load(as: UInt32.self) }))
    let headerJSON = try JSONSerialization.jsonObject(with: prefix[4...]) as! [String: Any]
    try assertEqual(headerJSON["secKey"] as? String, "k")
    try assertEqual(headerLen, prefix.count - 4)
}

test("TCP header contains required keys") {
    let prefix = try buildTCPHeader(fileLength: 3_840_000, secKey: "mysecret")
    let headerJSON = try JSONSerialization.jsonObject(with: prefix[4...]) as! [String: Any]
    for key in ["num", "total", "fileLength", "fileName", "fileType", "secKey", "version"] {
        guard headerJSON[key] != nil else {
            throw NSError(domain: "assert", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Missing key: \(key)"])
        }
    }
}

test("fileLength in TCP header matches actual data length") {
    let fileLen = 4_123_456
    let prefix  = try buildTCPHeader(fileLength: fileLen, secKey: "x")
    let headerJSON = try JSONSerialization.jsonObject(with: prefix[4...]) as! [String: Any]
    try assertEqual(headerJSON["fileLength"] as? Int, fileLen)
}

test("secKey is passed through correctly") {
    let key    = "Samsung2021FrameSecKey"
    let prefix = try buildTCPHeader(fileLength: 100, secKey: key)
    let headerJSON = try JSONSerialization.jsonObject(with: prefix[4...]) as! [String: Any]
    try assertEqual(headerJSON["secKey"] as? String, key)
}

// ── 5. Edge cases ─────────────────────────────────────────────────────────────
print("\n5. Edge cases")

test("parseArtEvent returns nil for garbage input") {
    try assertNil(parseArtEvent("not json at all"))
}

test("port parsed correctly when TV sends it as String") {
    let parsed: [String: Any] = ["event": "ready_to_use",
                                  "conn_info": #"{"port":"49200","key":"sk","ip":"1.2.3.4"}"#]
    let (port, _) = try extractConnInfo(parsed)
    try assertEqual(port, 49200)
}

test("select_image carries id and request_id") {
    let (_, inner) = try buildArtRequest([
        "request":    "select_image",
        "content_id": "MY_F0001",
        "show":       true
    ], clientId: testClientId)
    try assertEqual(inner["id"]         as? String, testClientId)
    try assertEqual(inner["request_id"] as? String, testClientId)
    try assertEqual(inner["content_id"] as? String, "MY_F0001")
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Summary
// ─────────────────────────────────────────────────────────────────────────────

let total = passed + failed
print("\n─────────────────────────────────────────")
print("  \(passed)/\(total) tests passed", failed > 0 ? "  ⚠️  \(failed) FAILED" : "  🎉")
print("─────────────────────────────────────────\n")

if failed > 0 { exit(1) }
