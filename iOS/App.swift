import SwiftUI
import AVFoundation
import Network

final class PhoneMic: ObservableObject {
    @Published var pairing = PairStore.load()
    @Published var status = "未连接"
    @Published var active = false
    @Published var meter: Float = 0
    @Published var muted = false
    private var engine: AVAudioEngine?
    private var wire: Wire?
    private var epoch = 0
    private var retry: DispatchWorkItem?
    private var retryCount = 0
    private var sending = false
    private var diagnostics: [String: Any] = [:]
    private var diagnosticTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.diagnostics["status"] = self.status; self.diagnostics["meter"] = self.meter
            self.diagnostics["time"] = Date().timeIntervalSince1970
            self.diagnostics["wire"] = self.wire?.snapshot
            self.diagnostics["sending"] = self.sending
            let url = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("diagnostics.json")
            try? JSONSerialization.data(withJSONObject:self.diagnostics,options:.sortedKeys).write(to:url,options:.atomic)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in self?.stop("录音被中断，请重新开始") })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.active, let value = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, let reason = AVAudioSession.RouteChangeReason(rawValue: value) else { return }
            if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable { self.stop("麦克风已切换，请重新开始") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in self?.stop("音频服务已重置，请重新开始") })
    }
    func pair(_ url: String) {
        guard !active else { status = "请先停止录音再配对"; return }
        guard let p = Pairing.parse(url) else { status = "配对链接无效"; return }
        do { try PairStore.save(p); pairing = p; status = "已配对" }
        catch { status = error.localizedDescription }
    }
    func start() {
        guard !active, let pairing else { return }
        epoch += 1; let generation = epoch; status = "准备连接"
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.epoch == generation else { return }
                guard granted else { self.status = "请允许麦克风访问"; return }
                self.active = true; self.retryCount = 0
                do {
                    try self.capture(generation: generation)
                    self.connect(pairing, generation: generation)
                } catch { self.stop(error.localizedDescription) }
            }
        }
    }
    private func connect(_ pairing: Pairing, generation: Int) {
        guard active, epoch == generation else { return }
        retry = nil; sending = false
        do {
            let wire = Wire(NWConnection(host: NWEndpoint.Host(pairing.host), port: NWEndpoint.Port(rawValue: pairing.port)!, using: try micParameters(pairing)))
            self.wire = wire; status = retryCount == 0 ? "连接中" : "重新连接中"
            wire.onReady = { [weak self, weak wire] in
                guard let self, let wire, self.active, self.epoch == generation, self.wire === wire else { return }
                do {
                    wire.send(1, try JSONEncoder().encode(Hello(name: UIDevice.current.name)))
                    self.status = "连接中"
                } catch { self.stop(error.localizedDescription) }
            }
            wire.onFrame = { [weak self, weak wire] kind, payload in
                guard let self, let wire, self.active, self.epoch == generation, self.wire === wire else { return }
                if kind == 3 { self.stop("Mac 已停止接收") }
                else if kind == 6 {
                    self.muted = payload.first == 1
                    self.sending = true; self.retryCount = 0; self.status = "传送中"
                }
            }
            wire.onClose = { [weak self, weak wire] reason in
                guard let self, let wire, self.active, self.epoch == generation, self.wire === wire else { return }
                self.wire = nil; self.sending = false
                self.scheduleReconnect(pairing, generation: generation, reason: reason)
            }
            wire.start()
        } catch { stop(error.localizedDescription) }
    }
    private func scheduleReconnect(_ pairing: Pairing, generation: Int, reason: String) {
        guard active, epoch == generation else { return }
        retryCount += 1; status = "重新连接中"
        diagnostics["reconnect_count"] = (diagnostics["reconnect_count"] as? Int ?? 0) + 1
        diagnostics["last_disconnect"] = reason
        let delay = min(8.0, pow(2.0, Double(min(retryCount - 1, 3))))
        let work = DispatchWorkItem { [weak self] in self?.connect(pairing, generation: generation) }
        retry?.cancel(); retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func capture(generation: Int) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .allowBluetoothHFP])
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        let engine = AVAudioEngine(), input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0, source.commonFormat == .pcmFormatFloat32 else { throw MicError.message("麦克风格式不可用") }
        diagnostics["source_format"] = source.description
        diagnostics["route"] = session.currentRoute.inputs.map { $0.portType.rawValue }
        diagnostics["voice_processing"] = input.isVoiceProcessingEnabled
        let encoder = try AACEncoder()
        input.installTap(onBus: 0, bufferSize: 960, format: source) { [weak self] buffer, _ in
            guard let self else { return }
            let result: (pcm: EncodedPCM, packets: [AACFrame])
            do { guard let encoded = try encoder.encode(buffer) else { return }; result = encoded }
            catch { DispatchQueue.main.async { self.stop(error.localizedDescription) }; return }
            let encoded = result.pcm
            let rms = encoded.rms, stamp = ProcessInfo.processInfo.systemUptime
            let inputFrames = Int(buffer.frameLength), outputFrames = encoded.frames
            DispatchQueue.main.async {
                self.diagnostics["tap_count"] = (self.diagnostics["tap_count"] as? Int ?? 0) + 1
                self.diagnostics["input_frames"] = inputFrames
                self.diagnostics["converted_frames"] = outputFrames
                self.diagnostics["conversion_status"] = 0
                self.diagnostics["conversion_error"] = 0
            }
            DispatchQueue.main.async {
                guard self.active, self.epoch == generation else { return }
                self.meter = rms
                guard self.sending, !self.muted else { return }
                self.diagnostics["aac_packets"] = (self.diagnostics["aac_packets"] as? Int ?? 0) + result.packets.count
                self.diagnostics["aac_bytes"] = (self.diagnostics["aac_bytes"] as? Int ?? 0) + result.packets.reduce(0) { $0 + $1.packet.count }
                for frame in result.packets { self.wire?.send(2, audioEnvelope(frame, uptime: stamp)) }
            }
        }
        self.engine = engine
        try engine.start()
    }
    func stop(_ reason: String = "已停止") {
        epoch += 1; active = false; sending = false
        retry?.cancel(); retry = nil; retryCount = 0
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        let old = wire; wire = nil; old?.send(3, Data()); old?.close()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        meter = 0; muted = false; status = reason
    }
}

struct PhoneView: View {
    @ObservedObject var mic: PhoneMic
    @State private var showPairing = false
    @State private var pairingText = ""
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Text(MicAppearance.name).font(.system(size: 20, weight: .semibold)).tracking(-0.6).lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: 8)
                        Button { showPairing = true } label: { Image(systemName: "qrcode") }
                            .buttonStyle(MicIconButtonStyle()).accessibilityLabel("配对")
                    }
                    Text(mic.muted ? "Mac 已静音" : mic.status)
                        .font(.system(size: 15)).foregroundStyle(MicAppearance.muted).padding(.top, 65)
                    Text(mic.pairing?.name ?? "连接 Mac")
                        .font(.system(size: 28, weight: .semibold)).tracking(-0.6)
                        .padding(.top, 12).lineLimit(2)
                    MicWaveform(level: mic.meter, active: mic.active && !mic.muted)
                        .padding(.vertical, 50)
                    Button { mic.active ? mic.stop() : mic.start() } label: {
                        Image(systemName: mic.active ? "stop.fill" : "mic")
                            .font(.system(size: 34, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 100, height: 100)
                            .background(MicAppearance.gradient, in: Circle())
                            .shadow(color: MicAppearance.blue.opacity(0.15), radius: 12, y: 6)
                    }.buttonStyle(.plain).disabled(mic.pairing == nil)
                        .accessibilityLabel(mic.active ? "停止录音" : "开始录音")
                        .frame(maxWidth: .infinity)
                    Text(mic.active ? "停止" : "开始").font(.system(size: 16))
                        .foregroundStyle(MicAppearance.muted).padding(.top, 20).frame(maxWidth: .infinity)
                    Spacer(minLength: 30)
                    Label("加密连接", systemImage: "lock")
                        .font(.system(size: 13)).foregroundStyle(MicAppearance.muted)
                        .frame(maxWidth: .infinity)
                }.padding(30).frame(minHeight: geometry.size.height, alignment: .top)
            }.scrollIndicators(.hidden)
        }.background(Color.white).foregroundStyle(MicAppearance.ink)
            .tint(MicAppearance.blue).preferredColorScheme(.light)
            .sheet(isPresented: $showPairing) {
                NavigationStack {
                    Form {
                        TextField("配对链接", text: $pairingText).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("配对") { mic.pair(pairingText); pairingText = ""; showPairing = false }
                    }.navigationTitle("连接 Mac").toolbar { Button("取消") { showPairing = false } }
                }.tint(MicAppearance.blue).preferredColorScheme(.light)
            }
    }
}

@main struct RemoteMicPhone: App {
    @StateObject var mic = PhoneMic()
    var body: some Scene { WindowGroup { PhoneView(mic: mic).onOpenURL { mic.pair($0.absoluteString) } } }
}
