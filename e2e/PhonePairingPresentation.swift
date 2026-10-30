import Foundation

@main
struct PhonePairingPresentationTests {
    static func main() {
        var failures = 0
        func expect(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("PASS \(name)") }
            else { failures += 1; print("FAIL \(name) \(detail)") }
        }

        let key = String(repeating: "ab", count: 32)
        let otherKey = String(repeating: "cd", count: 32)
        let paired = Pairing(host: "100.95.36.100", port: 48139, key: key, name: "Steve's Mac Studio")
        let emptyHost = Pairing(host: "", port: 48139, key: key, name: "Ghost Mac")
        let emptyName = Pairing(host: "192.168.1.8", port: 48139, key: key, name: "  ")

        let fresh = PhonePairingPresentation.kind(pairing: nil, acknowledgedKey: nil)
        expect("fresh-unpaired", fresh == .unpaired)
        expect("fresh-title", PhonePairingPresentation.title(fresh) == PhonePairingPresentation.unpairedTitle)
        expect("fresh-no-address", PhonePairingPresentation.showsAddress(fresh) == false)
        expect("fresh-cannot-start", PhonePairingPresentation.canStart(fresh) == false)

        let empty = PhonePairingPresentation.kind(pairing: emptyHost, acknowledgedKey: key)
        expect("empty-host-unpaired", empty == .unpaired)
        expect("empty-host-title", PhonePairingPresentation.title(empty) == "未配对 · 扫码连接 Mac")

        let restored = PhonePairingPresentation.kind(pairing: paired, acknowledgedKey: nil)
        expect("keychain-restore", restored == .restored(name: "Steve's Mac Studio"))
        expect("restore-title", PhonePairingPresentation.title(restored) == "上次配对：Steve's Mac Studio")
        expect("restore-shows-address", PhonePairingPresentation.showsAddress(restored))
        expect("restore-can-start", PhonePairingPresentation.canStart(restored))

        let wrongAck = PhonePairingPresentation.kind(pairing: paired, acknowledgedKey: otherKey)
        expect("wrong-ack-still-restored", wrongAck == .restored(name: "Steve's Mac Studio"))

        let confirmed = PhonePairingPresentation.kind(pairing: paired, acknowledgedKey: key)
        expect("after-scan-paired", confirmed == .paired(name: "Steve's Mac Studio"))
        expect("paired-title-is-payload-name", PhonePairingPresentation.title(confirmed) == "Steve's Mac Studio")
        expect("paired-can-start", PhonePairingPresentation.canStart(confirmed))

        let blankName = PhonePairingPresentation.kind(pairing: emptyName, acknowledgedKey: key)
        expect("blank-name-falls-back", blankName == .paired(name: "Mac"))

        if failures > 0 {
            fputs("PhonePairingPresentation tests failed: \(failures)\n", stderr)
            exit(1)
        }
        print("PhonePairingPresentation tests passed")
    }
}
