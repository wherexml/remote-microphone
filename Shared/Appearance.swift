import SwiftUI
import Combine

enum MicAppearance {
    static let name = "Remote Microphone"
    static let blue = Color(red: 0.20, green: 0.533, blue: 1)
    static let blueEnd = Color(red: 0.298, green: 0.58, blue: 1)
    static let ink = Color(red: 0.125, green: 0.137, blue: 0.165)
    static let muted = Color(red: 0.49, green: 0.518, blue: 0.565)
    static let surface = Color(red: 0.965, green: 0.969, blue: 0.98)
    static let pale = Color(red: 0.918, green: 0.949, blue: 1)
    static let border = Color(red: 0.91, green: 0.918, blue: 0.941)
    static let idle = Color(red: 0.847, green: 0.867, blue: 0.902)
    static let gradient = LinearGradient(colors: [blue, blueEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct MicIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 17, weight: .medium))
            .frame(width: 36, height: 36)
            .foregroundStyle(MicAppearance.blue)
            .background(MicAppearance.pale, in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
struct MicPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity).frame(height: 46)
            .foregroundStyle(.white)
            .background(MicAppearance.gradient, in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

// Show recent measured levels, not an ornamental animation that moves in silence.
struct MicWaveform: View {
    let level: Float
    let active: Bool
    @State private var history = Array(repeating: Float(0), count: 24)
    @State private var peak: Float = 0
    @State private var envelope: Float = 0
    // Keep the publisher's identity across input updates. Creating it in body
    // continually cancels/restarts the subscription under live audio input.
    @State private var ticker = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<24, id: \.self) { index in
                Capsule().fill(active ? MicAppearance.blue : MicAppearance.idle)
                    .frame(width: 5, height: 5 + CGFloat(active ? history[index] : 0) * 60)
            }
        }.frame(maxWidth: .infinity).frame(height: 70)
            .animation(reduceMotion ? nil : .linear(duration: 1.0 / 30), value: history)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("音量")
            .accessibilityValue("\(Int((active ? Self.visibleLevel(level) : 0) * 100))%")
            .onChange(of: level) { _, value in
                peak = max(peak, value.isFinite ? max(0, value) : 0)
            }
            .onReceive(ticker) { _ in
                guard active else { return }
                let current = level.isFinite ? max(0, level) : 0
                // Logarithmic display only: quiet speech remains visible without
                // altering the recorded/transmitted samples or moving in silence.
                let target = Self.visibleLevel(max(peak, current))
                envelope = max(target, envelope * 0.76)
                if envelope < 0.005 { envelope = 0 }
                history.removeFirst(); history.append(envelope); peak = 0
            }
            .onAppear { reset() }
            .onChange(of: active) { _, _ in reset() }
    }
    private func reset() {
        history = Array(repeating: 0, count: 24); peak = 0; envelope = 0
    }
    private static func visibleLevel(_ rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 60) / 42))
    }
}
