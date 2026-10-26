import Foundation
import Network

let outputPath = CommandLine.arguments.dropFirst().first ?? "artifacts/transport.json"
let p = try Pairing.fresh(host: "127.0.0.1", name: "E2E")
let listener = try NWListener(using: micParameters(p), on: 48149)
var server: Wire?
var client: Wire?
var bad: Wire?
var results: [String: Any] = ["kind": "real DTLS datagrams with synthetic PCM", "positive": false, "wrong_key_rejected": false]
var expected = Data()
for n in 0..<960 {
    var sample = Int16(sin(Double(n) * 2 * .pi * 440 / 48000) * 12000).littleEndian
    expected.append(withUnsafeBytes(of: &sample) { Data($0) })
}
var finished = false
func finish(_ ok: Bool) {
    guard !finished else { return }; finished = true
    results["passed"] = ok
    try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outputPath).deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: outputPath))
    print(ok ? "transport E2E PASS" : "transport E2E FAIL")
    exit(ok ? 0 : 1)
}
listener.newConnectionHandler = { connection in
    let w = Wire(connection); server = w
    w.diagnostic = { print("server", $0) }
    w.onFrame = { kind, payload in
        if kind == 2 {
            results["positive"] = payload == expected
            results["pcm_bytes"] = payload.count
            w.send(2, payload)
        }
    }
    w.start()
}
listener.stateUpdateHandler = { state in
    print("listener", state)
    guard case .ready = state else { return }
    let w = Wire(NWConnection(host: "127.0.0.1", port: 48149, using: try! micParameters(p))); client = w
    w.diagnostic = { print("client", $0) }
    w.onReady = { w.send(2, expected) }
    w.onFrame = { kind, payload in
        guard kind == 2 && payload == expected else { finish(false); return }
        w.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let badPair = try! Pairing.fresh(host: "127.0.0.1", name: "wrong")
            let b = Wire(NWConnection(host: "127.0.0.1", port: 48149, using: try! micParameters(badPair))); bad = b
            b.onReady = { results["wrong_key_rejected"] = false; finish(false) }
            b.onClose = { _ in results["wrong_key_rejected"] = true; finish(results["positive"] as? Bool == true) }
            b.start()
        }
    }
    w.onClose = { _ in }
    w.start()
}
listener.start(queue: .main)
DispatchQueue.main.asyncAfter(deadline: .now() + 55) { results["timeout"] = true; finish(false) }
dispatchMain()
