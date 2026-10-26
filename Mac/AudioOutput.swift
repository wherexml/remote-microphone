import AVFoundation
import CoreAudio

struct OutputDevice: Identifiable, Hashable {
    var id: AudioDeviceID
    var name: String
    var uid: String
}

func loopbackDevices() -> [OutputDevice] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var p = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString; var n = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &p, 0, nil, &n, &value) == noErr else { return "" }
        return value as String
    }
    return ids.compactMap { id in
        let uid = string(id, kAudioDevicePropertyDeviceUID)
        let name = string(id, kAudioObjectPropertyName)
        // Deliberately exclude speakers and unrelated loopback devices.
        guard uid.lowercased().contains("blackhole") else { return nil }
        return OutputDevice(id: id, name: name, uid: uid)
    }
}

// A bounded CoreAudio render ring avoids AVAudioPlayerNode completion timing
// differences on virtual devices. The render callback never allocates or blocks
// on networking; the lock protects only copying at most one small PCM packet.
final class AudioOutput {
    private var unit: AudioUnit?
    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 32768)
    private var head = 0, tail = 0, queued = 0
    private var rate = 48000.0
    private var phase = 0.0
    private var lastPacket = Date()
    private var watchdog: Timer?
    private(set) var receivedSamples = 0
    private(set) var droppedPackets = 0
    private(set) var renderedSamples = 0
    var level: ((Float) -> Void)?

    func start(device: OutputDevice) throws {
        stop()
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw MicError.message("音频输出不可用") }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created))
        guard let created else { throw MicError.message("音频输出不可用") }
        unit = created
        do {
            var id = device.id
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, 4))
            var hardware = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout.size(ofValue: hardware))
            try check(AudioUnitGetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &hardware, &size))
            guard hardware.mSampleRate >= 8000, hardware.mSampleRate <= 192000, hardware.mChannelsPerFrame > 0 else { throw MicError.message("虚拟麦克风格式不可用") }
            rate = hardware.mSampleRate; phase = 0
            var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: hardware.mChannelsPerFrame, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout.size(ofValue: format))))
            var callback = AURenderCallbackStruct(inputProc: { context, _, _, _, frames, data in
                guard let data else { return noErr }
                let output = Unmanaged<AudioOutput>.fromOpaque(context).takeUnretainedValue()
                output.render(frames: Int(frames), buffers: UnsafeMutableAudioBufferListPointer(data))
                return noErr
            }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout.size(ofValue: callback))))
            try check(AudioUnitInitialize(created))
            try check(AudioOutputUnitStart(created))
            lastPacket = Date()
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastPacket) > 0.3 { self.flush() }
            }
        } catch { stop(); throw error }
    }
    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw MicError.message("虚拟麦克风连接失败（\(status)）") }
    }
    private func render(frames: Int, buffers: UnsafeMutableAudioBufferListPointer) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<frames {
            var value: Float = 0
            if queued > 0 { value = ring[head]; head = (head + 1) % ring.count; queued -= 1; renderedSamples += 1 }
            for buffer in buffers {
                guard let pointer = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = Int(buffer.mNumberChannels)
                for c in 0..<channels { pointer[i * channels + c] = value }
            }
        }
    }
    func write(_ pcm: Data) {
        guard unit != nil, pcm.count % 2 == 0, !pcm.isEmpty, pcm.count <= 8192 else { return }
        lastPacket = Date()
        let count = pcm.count / 2
        var samples = [Float](repeating: 0, count: count)
        var energy: Float = 0
        pcm.withUnsafeBytes { bytes in
            for i in 0..<count {
                let value = Float(bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self).littleEndian) / 32768
                samples[i] = value; energy += value * value
            }
        }
        lock.lock()
        let needed = Int(ceil(Double(count) * rate / 48000))
        if queued + needed > min(ring.count, Int(rate * 0.16)) {
            droppedPackets += 1; head = 0; tail = 0; queued = 0
        }
        // Maintain fractional position across packets when the driver uses a
        // different sample rate; mono is duplicated into every output channel.
        while phase < Double(count) {
            let i = Int(phase), fraction = Float(phase - Double(i))
            let value = samples[i] + (samples[min(i + 1, count - 1)] - samples[i]) * fraction
            ring[tail] = value; tail = (tail + 1) % ring.count; queued += 1
            phase += 48000 / rate
        }
        phase -= Double(count)
        receivedSamples += count
        lock.unlock()
        level?(sqrt(energy / Float(count)))
    }
    func flush() {
        lock.lock(); head = 0; tail = 0; queued = 0; phase = 0; lock.unlock()
        level?(0)
    }
    func stop() {
        watchdog?.invalidate(); watchdog = nil
        if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        unit = nil; flush()
    }
}
