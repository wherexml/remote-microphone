import AVFoundation

struct AACFrame {
    let packet: Data
    let cookie: Data
}

func aacFormat() -> AVAudioFormat {
    AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVSampleRateKey: 48000,
                            AVNumberOfChannelsKey: 1,
                            AVEncoderBitRateKey: 32000])!
}

final class AACEncoder {
    private let pcm = PCMEncoder()
    private var streamCookie: Data?
    private let floatFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private let format = aacFormat()
    private let converter: AVAudioConverter
    init() throws {
        guard let converter = AVAudioConverter(from: floatFormat, to: format) else { throw MicError.message("语音编码不可用") }
        converter.bitRate = 32000
        self.converter = converter
    }
    func encode(_ source: AVAudioPCMBuffer) throws -> (pcm: EncodedPCM, packets: [AACFrame])? {
        guard let encoded = pcm.encode(source), let input = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(encoded.frames)) else { return nil }
        input.frameLength = AVAudioFrameCount(encoded.frames)
        encoded.data.withUnsafeBytes { bytes in
            for i in 0..<encoded.frames { input.floatChannelData![0][i] = Float(bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self).littleEndian) / 32768 }
        }
        let output = AVAudioCompressedBuffer(format: format, packetCapacity: 16, maximumPacketSize: converter.maximumOutputPacketSize)
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard error == nil, status != .error else { throw MicError.message("语音编码失败") }
        // AAC cookie bitrate statistics may change during encoding; the initial
        // stream configuration remains valid for every packet in this session.
        if streamCookie == nil, output.packetCount > 0 { streamCookie = converter.magicCookie ?? Data() }
        let cookie = streamCookie ?? Data()
        guard cookie.count <= 512 else { throw MicError.message("编码参数无效") }
        var packets: [AACFrame] = []
        for i in 0..<Int(output.packetCount) {
            guard let descriptions = output.packetDescriptions else { throw MicError.message("编码包无效") }
            let desc = descriptions[i], start = Int(descriptions[i].mStartOffset)
            guard start >= 0, desc.mDataByteSize > 0, start + Int(desc.mDataByteSize) <= Int(output.byteLength), desc.mDataByteSize <= 4096 else { throw MicError.message("编码包无效") }
            packets.append(AACFrame(packet: Data(bytes: output.data.advanced(by: start), count: Int(desc.mDataByteSize)), cookie: cookie))
        }
        return (encoded, packets)
    }
}

final class AACDecoder {
    private let format = aacFormat()
    private let floatFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private let converter: AVAudioConverter
    private var cookie: Data?
    init() throws {
        guard let converter = AVAudioConverter(from: format, to: floatFormat) else { throw MicError.message("语音解码不可用") }
        self.converter = converter
    }
    func decode(packet: Data, cookie: Data) throws -> Data {
        guard !packet.isEmpty, packet.count <= 4096, cookie.count <= 512 else { throw MicError.message("无效语音包") }
        if self.cookie == nil { if !cookie.isEmpty { converter.magicCookie = cookie }; self.cookie = cookie }
        guard self.cookie == cookie else { throw MicError.message("语音编码参数发生变化") }
        let input = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: packet.count)
        input.packetCount = 1; input.byteLength = UInt32(packet.count)
        packet.withUnsafeBytes { bytes in input.data.copyMemory(from: bytes.baseAddress!, byteCount: packet.count) }
        input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 1024, mDataByteSize: UInt32(packet.count))
        let output = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: 1024)!
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard error == nil, status != .error else { throw MicError.message("语音解码失败") }
        var samples = [Int16](); samples.reserveCapacity(Int(output.frameLength))
        for i in 0..<Int(output.frameLength) {
            let sample = output.floatChannelData![0][i]
            samples.append(Int16((max(-1, min(1, sample.isFinite ? sample : 0)) * 32767).rounded()).littleEndian)
        }
        return samples.withUnsafeBytes { Data($0) }
    }
}

func audioEnvelope(_ frame: AACFrame, uptime: Double) -> Data {
    var stamp = uptime.bitPattern.bigEndian, count = UInt16(frame.cookie.count).bigEndian
    var data = withUnsafeBytes(of: &stamp) { Data($0) }
    data.append(withUnsafeBytes(of: &count) { Data($0) }); data.append(frame.cookie); data.append(frame.packet)
    return data
}
