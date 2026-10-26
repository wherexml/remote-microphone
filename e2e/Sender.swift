import Foundation
import Network
import AVFoundation

@main struct Sender {
 static var wire: Wire?
 static var timer: DispatchSourceTimer?
 static func main() throws {
    guard CommandLine.arguments.count == 2, var p = Pairing.parse(try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)) else { exit(2) }
    p.host = "127.0.0.1" // Local receiver E2E; phone acceptance uses Tailscale.
    let w = Wire(NWConnection(host: NWEndpoint.Host(p.host), port: NWEndpoint.Port(rawValue: p.port)!, using: try micParameters(p)))
    wire = w
    var index = 0
    let encoder = try AACEncoder()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    w.onReady = {
        w.send(1, try! JSONEncoder().encode(Hello(name: "E2E • 440 Hz")))
        let started = Date()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 8 { t.cancel(); w.send(3, Data()); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }; return }
            let stamp = ProcessInfo.processInfo.systemUptime - ((elapsed > 3 && elapsed < 5) ? 5 : 0)
            // Mimic iPhone: 100 ms Float32 callbacks, deliberately larger capacity.
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4864)!
            buffer.frameLength = 4800
            for i in 0..<4800 {
                buffer.floatChannelData![0][i] = Float(sin(Double(index) * 2 * .pi * 440 / 48000) * 12000 / 32768); index += 1
            }
            let encoded = try! encoder.encode(buffer)!
            guard encoded.pcm.frames == 4800 else { print("Incorrect encoded frame count"); exit(4) }
            for frame in encoded.packets { w.send(2, audioEnvelope(frame, uptime: stamp)) }
        }
        timer = t; t.resume()
        print("Sending synthetic tone, stale packets, fresh tone, then stop")
    }
    w.onClose = { reason in print(reason); exit(0) }
    w.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(3) }
    dispatchMain()
 }
}
