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

/// Compact connection/send state glyph next to the status label.
enum MicLinkPhase: Equatable {
    case idle
    case connecting
    case sending
    case error
    static func from(status: String, active: Bool, sending: Bool = false, connected: Bool = false) -> MicLinkPhase {
        let errorHints = ["失败", "中断", "超时", "无效", "不匹配", "请允许", "未安装", "请先", "请粘贴", "请扫描", "配对码无效", "配对链接无效"]
        if errorHints.contains(where: { status.contains($0) }) { return .error }
        if sending || status == "传送中" || status.hasPrefix("正在传送") { return .sending }
        if status == "未连接" || status == "未启动" || status == "已停止" || status == "已配对" { return .idle }
        if active || connected || status == "连接中" || status == "重新连接中" || status == "准备连接" || status == "等待连接" || status.hasPrefix("正在连接") || status.hasPrefix("正在重新连接") || status.hasPrefix("正在准备") {
            return .connecting
        }
        return .idle
    }
}

struct MicStatusIndicator: View {
    let phase: MicLinkPhase
    var level: Float = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        Group {
            switch phase {
            case .idle:
                Circle().fill(MicAppearance.idle).frame(width: 8, height: 8)
            case .error:
                Circle().fill(Color.red.opacity(0.85)).frame(width: 8, height: 8)
            case .connecting:
                Circle()
                    .fill(MicAppearance.blue)
                    .frame(width: 8, height: 8)
                    .opacity(reduceMotion ? 1 : (pulse ? 0.25 : 1))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .onChange(of: phase) { _, _ in pulse = true }
            case .sending:
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule().fill(MicAppearance.blue)
                            .frame(width: 3, height: barHeight(index))
                    }
                }
                .frame(width: 14, height: 12)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: level)
            }
        }
        .accessibilityHidden(true)
    }
    private func barHeight(_ index: Int) -> CGFloat {
        let base: Float = reduceMotion ? 0.55 : max(0.2, min(1, level * 4 + 0.25))
        let factor: Float = [0.55, 1.0, 0.7][index]
        return CGFloat(4 + base * factor * 8)
    }
}

struct MicStatusLabel: View {
    let status: String
    let phase: MicLinkPhase
    var level: Float = 0
    var muted: Bool = false
    private var display: String {
        if muted { return "Mac 已静音" }
        switch status {
        case "连接中": return "正在连接 Mac"
        case "重新连接中": return "正在重新连接"
        case "传送中": return "正在传送声音"
        case "准备连接": return "正在准备连接"
        case "等待连接": return "等待手机连接"
        case "已连接": return "已连接，等待声音"
        case "未连接": return "尚未连接"
        case "未启动": return "接收未启动"
        case "已配对": return "已配对，可以开始"
        case "已停止": return "已停止"
        default: return status
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            MicStatusIndicator(phase: phase, level: level)
            Text(display)
                .font(.system(size: 15))
                .foregroundStyle(phase == .error ? Color.red.opacity(0.9) : MicAppearance.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(display)
    }
}
