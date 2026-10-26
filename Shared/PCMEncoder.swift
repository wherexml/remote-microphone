import AVFoundation

struct EncodedPCM {
    let data: Data
    let frames: Int
    let rms: Float
}

// One instance per recording session, called only by that session's audio tap.
// frameLength is authoritative; frameCapacity must never become extra audio.
final class PCMEncoder {
    private var phase = 0.0
    func encode(_ buffer: AVAudioPCMBuffer) -> EncodedPCM? {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData, buffer.frameLength > 0,
              buffer.format.sampleRate > 0 else { return nil }
        let frames = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return nil }
        let interleaved = buffer.format.isInterleaved, rate = buffer.format.sampleRate
        func mono(_ index: Int) -> Float {
            var sum: Float = 0
            for channel in 0..<channelCount {
                let value = interleaved ? channels[0][index * channelCount + channel] : channels[channel][index]
                sum += value.isFinite ? value : 0
            }
            return sum / Float(channelCount)
        }
        var samples: [Int16] = []
        samples.reserveCapacity(Int(ceil(Double(frames) * 48000 / rate)))
        var energy: Float = 0
        while phase < Double(frames) {
            let index = Int(phase), fraction = Float(phase - Double(index))
            let first = mono(index)
            let value = max(-1, min(1, first + (mono(min(index + 1, frames - 1)) - first) * fraction))
            samples.append(Int16((value * 32767).rounded()).littleEndian)
            energy += value * value
            phase += rate / 48000
        }
        phase -= Double(frames)
        guard !samples.isEmpty else { return nil }
        let pcm = samples.withUnsafeBytes { Data($0) }
        return EncodedPCM(data: pcm, frames: samples.count, rms: sqrt(energy / Float(samples.count)))
    }
}
