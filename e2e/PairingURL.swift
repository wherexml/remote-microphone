import Foundation

@main
struct PairingURLTests {
    static func main() {
        var failures = 0
        func expect(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("PASS \(name)") }
            else { failures += 1; print("FAIL \(name) \(detail)") }
        }

        func sample(host: String, name: String = "Studio") -> Pairing {
            Pairing(host: host, port: 48139, key: String(repeating: "ab", count: 32), name: name)
        }

        let cases: [(String, String)] = [
            ("lan-ipv4", "192.168.1.20"),
            ("tailscale-100", "100.64.12.34"),
            ("hostname", "mac.tailnet.ts.net"),
        ]

        for (name, host) in cases {
            let pairing = sample(host: host)
            guard let url = pairing.url else {
                expect("\(name)-url", false, "url nil"); continue
            }
            expect("\(name)-query-form", url.absoluteString.contains("?p=") && !url.absoluteString.contains("#"), url.absoluteString)
            let parsed = Pairing.parse(url.absoluteString)
            expect("\(name)-roundtrip", parsed?.host == host && parsed?.port == 48139 && parsed?.name == "Studio", "got \(parsed?.host ?? "nil")")
        }

        let legacy = sample(host: "100.95.36.100")
        let data = try! JSONEncoder().encode(legacy)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let fragmentLink = "remotemic://pair#" + b64
        let legacyParsed = Pairing.parse(fragmentLink)
        expect("legacy-fragment", legacyParsed?.host == "100.95.36.100", legacyParsed?.host ?? "nil")

        expect("reject-bare-ip", Pairing.parse("100.64.12.34") == nil)
        expect("reject-host-port", Pairing.parse("100.64.12.34:48139") == nil)
        expect("reject-empty", Pairing.parse("") == nil)
        expect("reject-http", Pairing.parse("https://example.com") == nil)
        expect("reject-fragment-stripped", Pairing.parse("remotemic://pair") == nil)
        expect("empty-host-no-url", sample(host: "").url == nil)
        expect("whitespace-host-no-url", sample(host: "  ").url == nil)

        if failures > 0 {
            fputs("PairingURL tests failed: \(failures)\n", stderr)
            exit(1)
        }
        print("PairingURL tests passed")
    }
}
