import SwiftUI
import Combine

final class LevelFeed: ObservableObject {
    @Published var level: Float = 0
    @Published var active = true
    @Published var quiet = false
    private var timer: AnyCancellable?
    private var tick = 0
    init() {
        timer = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }; self.tick += 1
            let pulse = (sin(Double(self.tick) * 0.13) + 1) / 2
            self.level = self.quiet ? 0 : Float(0.003 + 0.017 * pulse)
        }
    }
}
struct VerifyView: View {
    @StateObject var feed = LevelFeed()
    var body: some View {
        VStack(spacing: 20) {
            Text("Waveform Verify — 模拟轻声").font(.headline)
            Text(String(format: "RMS %.4f · 50 Hz", feed.level)).monospacedDigit()
            MicWaveform(level: feed.level, active: feed.active)
            HStack {
                Button(feed.quiet ? "模拟轻声" : "静音") { feed.quiet.toggle() }
                Button(feed.active ? "停止" : "开始") { feed.active.toggle() }
            }
        }.padding(30).frame(width: 400).background(Color.white).foregroundStyle(Color.black)
    }
}
@main struct WaveformVerify: App {
    var body: some Scene { WindowGroup("Waveform Verify") { VerifyView() }.windowResizability(.contentSize) }
}
