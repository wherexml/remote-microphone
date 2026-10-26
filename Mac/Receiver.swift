import Foundation
import Network
import Combine

final class Receiver: ObservableObject {
    @Published var status = "未启动"
    @Published var phone = "等待 iPhone"
    @Published var active = false
    @Published var connected = false
    @Published var meter: Float = 0
    @Published var devices: [OutputDevice] = []
    @Published var selected: UInt32 = 0
    @Published var pairing: Pairing?
    @Published var muted = false { didSet { output.flush(); wire?.send(6, Data([muted ? 1 : 0])) } }
    let output = AudioOutput()
    private var listener: NWListener?
    private var wire: Wire?
    private var candidates: [ObjectIdentifier: Wire] = [:]
    private var ready = false
    private var decoder: AACDecoder?
    private var senderAnchor = 0.0
    private var receiverAnchor = 0.0
    private var audioFrames = 0
    private var lastAge: Double = 0
    private var diagnosticTimer: Timer?

    init() {
        pairing = PairStore.load()
        if pairing == nil {
            do {
                let p = try Pairing.fresh(host: "", name: Host.current().localizedName ?? "Mac")
                try PairStore.save(p); pairing = p
            } catch { status = error.localizedDescription }
        }
        refresh()
        output.level = { [weak self] in self?.meter = $0 }
        diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let directory = PairStore.namespace ?? "RemoteMic"
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(directory + "/diagnostics.json")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var info: [String: Any] = ["status":self.status,"connected":self.connected,"audio_frames":self.audioFrames,"last_packet_age":self.lastAge,"output_samples":self.output.receivedSamples,"output_drops":self.output.droppedPackets,"rendered_samples":self.output.renderedSamples,"meter":self.meter,"time":Date().timeIntervalSince1970]
            if let wire = self.wire { info["wire"] = wire.snapshot }
            try? JSONSerialization.data(withJSONObject: info, options: .sortedKeys).write(to:url,options:.atomic)
        }
    }
    func refresh() {
        devices = loopbackDevices()
        if !devices.contains(where: { $0.id == selected }) { selected = devices.first?.id ?? 0 }
    }
    func start() {
        guard !active, let pairing else { return }
        refresh()
        guard selected != 0 else { status = "未安装 BlackHole 音频设备"; return }
        do {
            let listener = try NWListener(using: micParameters(pairing), on: NWEndpoint.Port(rawValue: pairing.port)!)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.active = true; self.status = "等待连接"
                case .failed: self.stop(); self.status = "接收服务启动失败"
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: .main); self.listener = listener
        } catch { status = error.localizedDescription }
    }
    private func accept(_ connection: NWConnection) {
        guard candidates.count < 4 else { connection.cancel(); return }
        let wire = Wire(connection)
        let identifier = ObjectIdentifier(wire)
        candidates[identifier] = wire
        wire.onFrame = { [weak self, weak wire] kind, payload in
            guard let self, let wire else { return }
            if kind == 1 {
                guard self.wire !== wire, let hello = try? JSONDecoder().decode(Hello.self, from: payload), hello.version == 4, hello.sentUptime.isFinite, hello.sampleRate == 48000, hello.channels == 1, hello.format == "aac-lc", let device = self.devices.first(where: { $0.id == self.selected }) else {
                    wire.close("音频格式不匹配"); return
                }
                // Only a peer that completed PSK authentication and a valid
                // HELLO can replace the current session. Pending handshakes
                // never hold the receiver's single audio slot.
                self.wire?.close("已由新连接替换")
                self.candidates.removeValue(forKey: identifier)
                self.wire = wire; self.ready = false
                self.senderAnchor = hello.sentUptime
                self.receiverAnchor = ProcessInfo.processInfo.systemUptime
                do { self.decoder = try AACDecoder(); try self.output.start(device: device) }
                catch { wire.close(error.localizedDescription); return }
                self.ready = true; self.connected = true
                self.phone = String(hello.name.prefix(80)); self.status = "已连接"
                wire.send(6, Data([self.muted ? 1 : 0]))
            } else if kind == 2 {
                guard self.wire === wire, self.ready else { return }
                guard payload.count >= 11, payload.count <= 4618 else { wire.close("无效音频帧"); return }
                // Compare elapsed monotonic time since HELLO on each device.
                // Wall clocks can differ; only extra queue delay matters.
                let stamp = payload.withUnsafeBytes { Double(bitPattern: $0.loadUnaligned(as: UInt64.self).bigEndian) }
                let age = (ProcessInfo.processInfo.systemUptime - self.receiverAnchor) - (stamp - self.senderAnchor)
                self.audioFrames += 1; self.lastAge = age.isFinite ? age : -9999
                guard stamp.isFinite, age >= -5, age < 0.5 else { self.output.flush(); return }
                let cookieLength = payload.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt16.self).bigEndian) }
                guard cookieLength <= 512, payload.count > 10 + cookieLength else { wire.close("无效语音包"); return }
                do {
                    let pcm = try self.decoder?.decode(packet: Data(payload.dropFirst(10 + cookieLength)), cookie: Data(payload[10..<(10 + cookieLength)])) ?? Data()
                    if !self.muted { self.output.write(pcm); self.status = "传送中" }
                } catch { wire.close(error.localizedDescription) }
            } else if kind == 3 { wire.close("手机已停止") }
            else { wire.close("音频协议不匹配") }
        }
        wire.onClose = { [weak self, weak wire] reason in
            guard let self else { return }
            self.candidates.removeValue(forKey: identifier)
            guard self.wire === wire else { return }
            self.output.stop(); self.decoder = nil; self.wire = nil; self.ready = false
            self.connected = false; self.phone = "等待 iPhone"; self.status = reason
        }
        wire.start()
    }
    func stop() {
        listener?.cancel(); listener = nil
        let pending = Array(candidates.values); candidates.removeAll()
        for candidate in pending { candidate.close() }
        wire?.send(3, Data()); wire?.close(); wire = nil
        output.stop(); active = false; connected = false; status = "已停止"
    }
    func updateHost(_ host: String) {
        guard !active, var pairing, !host.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        pairing.host = host.trimmingCharacters(in: .whitespaces)
        do { try PairStore.save(pairing); self.pairing = pairing }
        catch { status = error.localizedDescription }
    }
}
