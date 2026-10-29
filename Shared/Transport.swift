import Foundation
import Network
import Security

struct Pairing: Codable {
    var host: String
    var port: UInt16 = 48139
    var key: String
    var name: String = "Mac"
    var secret: Data? {
        guard key.count == 64 else { return nil }
        var bytes = Data()
        var index = key.startIndex
        while index < key.endIndex {
            let end = key.index(index, offsetBy: 2)
            guard let byte = UInt8(key[index..<end], radix: 16) else { return nil }
            bytes.append(byte); index = end
        }
        return bytes
    }
    static func fresh(host: String, name: String) throws -> Pairing {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MicError.message("无法生成配对密钥")
        }
        return Pairing(host: host, key: bytes.map { String(format: "%02x", $0) }.joined(), name: name)
    }
    /// Payload for QR / paste links. Prefer the query form: system Camera and
    /// some URL openers drop the fragment, which used to make a valid QR look
    /// like a bare address after scanning.
    private var payloadBase64: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    var url: URL? {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let b64 = payloadBase64 else { return nil }
        var components = URLComponents()
        components.scheme = "remotemic"
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "p", value: b64)]
        return components.url
    }
    /// Legacy fragment links (`remotemic://pair#…`) remain readable so older
    /// Mac builds and already-copied paste strings still pair.
    static func parse(_ text: String) -> Pairing? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "remotemic", url.host == "pair" else { return nil }
        let b64Source: String?
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            b64Source = items.first(where: { $0.name == "p" })?.value
        } else {
            b64Source = nil
        }
        guard var b64 = b64Source ?? url.fragment, !b64.isEmpty else { return nil }
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), let p = try? JSONDecoder().decode(Pairing.self, from: data), p.secret != nil, !p.host.isEmpty, p.port > 1024 else { return nil }
        return p
    }
}

enum MicError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

enum PairStore {
    // Release builds opt into isolated storage; existing development installs
    // retain their original pairing without migration or Keychain prompts.
    static let namespace = Bundle.main.object(forInfoDictionaryKey: "RemoteMicStorageNamespace") as? String
    static let service = namespace.map { $0 + ".pairing" } ?? "cc.skylance.remotemic.pairing"
    static func load() -> Pairing? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "primary", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }
    static func save(_ pairing: Pairing) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "primary"]
        let data = try JSONEncoder().encode(pairing)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MicError.message("配对保存失败（\(status)）") }
    }
}

func micParameters(_ pairing: Pairing) throws -> NWParameters {
    guard let key = pairing.secret else { throw MicError.message("配对信息无效") }
    let tls = NWProtocolTLS.Options()
    let identity = Data("remote-mic-v1".utf8)
    let keyDispatch = key.withUnsafeBytes { DispatchData(bytes: $0) }
    let idDispatch = identity.withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyDispatch as __DispatchData, idDispatch as __DispatchData)
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .DTLSv12)
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .DTLSv12)
    sec_protocol_options_add_tls_ciphersuite(tls.securityProtocolOptions, SSLCipherSuite(TLS_PSK_WITH_AES_128_GCM_SHA256))
    let params = NWParameters(dtls: tls, udp: NWProtocolUDP.Options())
    params.serviceClass = .interactiveVoice
    params.includePeerToPeer = true
    return params
}

struct Hello: Codable {
    var version = 4
    var sentUptime = ProcessInfo.processInfo.systemUptime
    var sampleRate = 48000
    var channels = 1
    var format = "aac-lc"
    var name: String
}

// All methods and callbacks belong to the main queue. Audio callbacks copy data
// before dispatching here. Payloads are never logged.
final class Wire {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onFrame: ((UInt8, Data) -> Void)?
    var onClose: ((String) -> Void)?
    var diagnostic: ((String) -> Void)?
    private var sendSequence: UInt64 = 0
    private var receivedSequence: UInt64 = 0
    private var pendingHello: Data?
    private var receivedHello: Data?
    private var muteState: Data?
    private var pendingBytes = 0
    private var closed = false
    private var established = false
    private var timer: DispatchSourceTimer?
    private var lastReceived = Date()
    private(set) var droppedFrames = 0
    var snapshot: [String: Any] { ["tx_sequence":sendSequence,"rx_sequence":receivedSequence,"pending_bytes":pendingBytes,"rx_age":Date().timeIntervalSince(lastReceived),"audio_drops":droppedFrames,"established":established] }

    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            self.diagnostic?(String(describing: state))
            switch state {
            case .ready:
                guard !self.established else { return }
                self.established = true; self.lastReceived = Date(); self.onReady?(); self.receive()
            case .failed: self.close("连接失败，请检查配对和网络")
            case .cancelled: self.close("已断开")
            default: break
            }
        }
        connection.start(queue: .main)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            if Date().timeIntervalSince(self.lastReceived) > (self.established ? 30 : 45) { self.close("连接超时"); return }
            if self.connection.state == .ready {
                if let hello = self.pendingHello { self.send(1, hello) }
                if let mute = self.muteState { self.send(6, mute) }
                self.send(4, Data())
            }
        }
        self.timer = timer; timer.resume()
    }
    func send(_ kind: UInt8, _ payload: Data) {
        guard !closed, payload.count <= 4096 else { return }
        if kind == 1 { pendingHello = payload }
        if kind == 6 { muteState = payload }
        if kind == 2 && pendingBytes > 2048 { droppedFrames += 1; return }
        sendSequence += 1
        var sequence = sendSequence.bigEndian
        var frame = Data([kind])
        frame.append(withUnsafeBytes(of: &sequence) { Data($0) }); frame.append(payload)
        let size = frame.count; pendingBytes += size
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes = max(0, self.pendingBytes - size)
            if error != nil { self.close("连接中断") }
        })
    }
    func close(_ reason: String = "已停止") {
        guard !closed else { return }; closed = true
        timer?.cancel(); timer = nil; pendingHello = nil; muteState = nil; connection.cancel()
        onClose?(reason)
    }
    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if let data, data.count >= 9, data.count <= 4105 {
                let kind = data[0]
                let sequence = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt64.self).bigEndian }
                if sequence > self.receivedSequence {
                    self.receivedSequence = sequence; self.lastReceived = Date()
                    let payload = Data(data.dropFirst(9))
                    if kind == 4 { self.send(5, Data()) }
                    else if kind == 7 { self.pendingHello = nil }
                    else if kind == 1 {
                        self.send(7, Data())
                        if let hello = self.receivedHello {
                            if hello != payload { self.close("音频协议不匹配"); return }
                        } else {
                            self.receivedHello = payload; self.onFrame?(kind, payload)
                        }
                    } else if kind != 5 { self.onFrame?(kind, payload) }
                }
            }
            if self.closed { return }
            if error != nil { self.close("已断开"); return }
            self.receive()
        }
    }
}
