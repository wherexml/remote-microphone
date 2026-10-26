import Foundation
import Network
import AVFoundation

@main struct Recovery {
    static var retained: [Wire] = []
    static var results: [String: Any] = ["kind":"installed receiver; real DTLS, PSK, AAC and BlackHole", "passed":false]
    static var finished = false
    static func receiver() -> [String: Any] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RemoteMic/diagnostics.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String:Any] ?? [:]
    }
    static func finish(_ passed: Bool) {
        guard !finished else { return }; finished = true
        results["passed"] = passed
        try? JSONSerialization.data(withJSONObject: results, options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:"artifacts/receiver-recovery.json"))
        print(passed ? "Receiver recovery E2E PASS" : "Receiver recovery E2E FAIL"); exit(passed ? 0 : 1)
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2, var p = Pairing.parse(try String(contentsOfFile:CommandLine.arguments[1])) else { exit(2) }
        p.host = "127.0.0.1"
        var badPair = try Pairing.fresh(host:p.host,name:"unauthenticated"); badPair.port = p.port
        let bad = Wire(NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:p.port)!,using:try micParameters(badPair)))
        retained.append(bad); bad.onReady = { finish(false) }; bad.start()
        func session(_ name: String, ready: @escaping (Wire) -> Void) {
            let w = Wire(NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:p.port)!,using:try! micParameters(p))); retained.append(w)
            let encoder = try! AACEncoder()
            let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
            var started = false, index = 0
            w.onReady = { w.send(1,try! JSONEncoder().encode(Hello(name:name))) }
            w.onFrame = { kind, _ in
                guard kind == 6, !started else { return }; started = true
                let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800)!; buffer.frameLength = 4800
                for n in 0..<4800 { buffer.floatChannelData![0][n] = Float(sin(Double(index)*2*Double.pi*440/48000)*0.2); index += 1 }
                for frame in try! encoder.encode(buffer)!.packets { w.send(2,audioEnvelope(frame,uptime:ProcessInfo.processInfo.systemUptime)) }
                ready(w)
            }
            w.start()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
            session("Recovery A") { first in
                results["unauthenticated_candidate_did_not_block"] = true
                DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                    let before = receiver()["output_samples"] as? Int ?? 0
                    session("Recovery B") { second in
                        results["fresh_authenticated_session_accepted"] = true
                        DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                            let state = receiver()
                            let delta = (state["output_samples"] as? Int ?? 0) - before
                            results["replacement_output_samples"] = delta
                            results["connected_after_replacement"] = state["connected"]
                            second.send(3,Data())
                            DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                                let stopped = receiver()["connected"] as? Bool == false
                                results["explicit_stop_disconnected"] = stopped
                                first.close(); bad.close()
                                finish(delta > 0 && state["connected"] as? Bool == true && stopped)
                            }
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+18) { results["timeout"] = true; finish(false) }
        dispatchMain()
    }
}
