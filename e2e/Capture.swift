import AppKit
import AVFoundation
import CoreAudio

final class CaptureDelegate: NSObject, NSApplicationDelegate {
    var unit: AudioUnit?
    var inputBuffer: AVAudioPCMBuffer?
    var renderError: OSStatus = noErr
    var started = Date()
    var file: AVAudioFile?
    var blocks: [[String: Double]] = []
    var stopSignal: DispatchSourceSignal?
    var finished = false
    var callbacks = 0
    var captureFormat = ""
    let lock = NSLock()
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REMOTE_MIC_ARTIFACTS"] ?? FileManager.default.currentDirectoryPath + "/artifacts")
    func applicationDidFinishLaunching(_ notification: Notification) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { if ok { self.run() } else { self.finish(error: "microphone permission denied") } }
        }
    }
    func run() {
        do {
            guard let device = loopbackDevices().first else { throw MicError.message("virtual input missing") }
            var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else { throw MicError.message("HAL input missing") }
            var created: AudioUnit?
            try check(AudioComponentInstanceNew(component, &created))
            guard let created else { throw MicError.message("HAL allocation failed") }; unit = created
            var enabled: UInt32 = 1, disabled: UInt32 = 0, id = device.id
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, 4))
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, 4))
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, 4))
            var actual: UInt32 = 0, size: UInt32 = 4
            try check(AudioUnitGetProperty(created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size))
            guard actual == id else { throw MicError.message("wrong input") }
            var hardware = AudioStreamBasicDescription(); size = UInt32(MemoryLayout.size(ofValue: hardware))
            try check(AudioUnitGetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size))
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw MicError.message("invalid hardware format") }
            var stream = format.streamDescription.pointee
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &stream, UInt32(MemoryLayout.size(ofValue: stream))))
            var maximum: UInt32 = 8192
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, 4))
            inputBuffer = buffer; captureFormat = format.description
            print("Capture hardware input:", format, "device", actual)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            file = try AVAudioFile(forWriting: root.appendingPathComponent("virtual-input.wav"), settings: format.settings)
            started = Date()
            var callback = AURenderCallbackStruct(inputProc: { context, flags, timestamp, _, frames, _ in
                let capture = Unmanaged<CaptureDelegate>.fromOpaque(context).takeUnretainedValue()
                guard let unit = capture.unit, let buffer = capture.inputBuffer, frames <= buffer.frameCapacity else { return kAudio_ParamError }
                buffer.frameLength = frames
                let result = AudioUnitRender(unit, flags, timestamp, 1, frames, buffer.mutableAudioBufferList)
                capture.lock.lock(); defer { capture.lock.unlock() }
                capture.callbacks += 1
                guard result == noErr, let samples = buffer.floatChannelData?[0], frames > 0 else { capture.renderError = result; return result }
                var energy = 0.0, crossings = 0
                for i in 0..<Int(frames) {
                    energy += Double(samples[i] * samples[i])
                    if i > 0 && samples[i-1] <= 0 && samples[i] > 0 { crossings += 1 }
                }
                do { try capture.file?.write(from: buffer) } catch { capture.renderError = kAudio_ParamError }
                capture.blocks.append(["t":Date().timeIntervalSince(capture.started), "rms":sqrt(energy/Double(frames)), "hz":Double(crossings)*buffer.format.sampleRate/Double(frames)])
                return noErr
            }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout.size(ofValue: callback))))
            try check(AudioUnitInitialize(created))
            try check(AudioOutputUnitStart(created))
            signal(SIGUSR1, SIG_IGN)
            let stopSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            stopSignal.setEventHandler { self.finish(error: nil) }
            self.stopSignal = stopSignal; stopSignal.resume()
            let duration = min(600, max(5, Double(ProcessInfo.processInfo.environment["REMOTE_MIC_CAPTURE_SECONDS"] ?? "20") ?? 20))
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { self.finish(error: nil) }
        } catch { finish(error: error.localizedDescription) }
    }
    func check(_ status: OSStatus) throws {
        guard status == noErr else { throw MicError.message("capture OSStatus \(status)") }
    }
    func finish(error: String?) {
        guard !finished else { return }; finished = true
        stopSignal?.cancel(); stopSignal = nil
        if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        unit = nil
        lock.lock(); let rows = blocks; file = nil; lock.unlock()
        var result: [String: Any] = ["source":"BlackHole virtual input only", "blocks":rows, "peak_block_rms": rows.map { $0["rms"] ?? 0 }.max() ?? 0, "nonzero_blocks":rows.filter { ($0["rms"] ?? 0) > 0.001 }.count, "captured_at":ISO8601DateFormatter().string(from: Date())]
        result["callbacks"] = callbacks; result["format"] = captureFormat
        if let error { result["error"] = error }
        else if renderError != noErr { result["error"] = "input render/write failure \(renderError)" }
        else if rows.isEmpty { result["error"] = callbacks == 0 ? "no input callbacks" : "no supported audio frames" }
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("virtual-input.json"))
        NSApplication.shared.terminate(nil)
    }
}
@main struct CaptureMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = CaptureDelegate(); app.delegate = delegate
        app.setActivationPolicy(.accessory); app.run()
    }
}
