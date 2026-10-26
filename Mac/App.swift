import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

struct ReceiverView: View {
    @ObservedObject var receiver: Receiver
    @State private var pairingShown = false
    @State private var host = ""
    @State private var devicePickerShown = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(MicAppearance.name).font(.system(size: 20, weight: .semibold))
                    .tracking(-0.6).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Button { pairingShown.toggle() } label: { Image(systemName: "qrcode") }
                    .buttonStyle(MicIconButtonStyle()).help("配对").accessibilityLabel("配对")
                    .popover(isPresented: $pairingShown, arrowEdge: .bottom) { pairingView }
            }
            Text(receiver.phone).font(.system(size: 19, weight: .semibold)).padding(.top, 26)
            Text(receiver.status).font(.system(size: 14)).foregroundStyle(MicAppearance.muted).padding(.top, 8)
            MicWaveform(level: receiver.meter, active: receiver.connected && !receiver.muted)
                .padding(.vertical, 28)
            HStack(spacing: 10) {
                Image(systemName: "mic").foregroundStyle(MicAppearance.muted)
                Button { devicePickerShown.toggle() } label: {
                    HStack {
                        Text(receiver.devices.first(where: { $0.id == receiver.selected })?.name ?? "未找到音频设备")
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                    }.foregroundStyle(MicAppearance.ink).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("音频设备")
                    .disabled(receiver.active).frame(maxWidth: .infinity)
                    .popover(isPresented: $devicePickerShown) {
                        VStack(spacing: 0) {
                            ForEach(receiver.devices) { device in
                                Button {
                                    receiver.selected = device.id; devicePickerShown = false
                                } label: {
                                    HStack {
                                        Text(device.name)
                                        Spacer()
                                        if receiver.selected == device.id { Image(systemName: "checkmark") }
                                    }.padding(12).frame(width: 250).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(4).foregroundStyle(MicAppearance.ink).background(Color.white)
                    }

            }.padding(.horizontal, 14).frame(height: 46)
                .background(MicAppearance.surface, in: RoundedRectangle(cornerRadius: 12))
            Button(receiver.active ? "停止接收" : "开始接收") { receiver.active ? receiver.stop() : receiver.start() }
                .buttonStyle(MicPrimaryButtonStyle()).padding(.top, 20)
        }.padding(.horizontal, 30).padding(.bottom, 30).padding(.top, 30)
            .frame(width: 350).background(Color.white)
            .foregroundStyle(MicAppearance.ink).tint(MicAppearance.blue).preferredColorScheme(.light)
            .onAppear { host = receiver.pairing?.host ?? "" }
    }
    private var pairingView: some View {
        VStack(spacing: 18) {
            HStack {
                Text("连接 iPhone").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button { pairingShown = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(MicIconButtonStyle()).accessibilityLabel("关闭配对")
            }
            if let url = receiver.pairing?.url {
                if let qr = qrImage(url.absoluteString) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 180, height: 180)
                }
            }
            TextField("Mac 的 Tailscale IP 或域名", text: $host).textFieldStyle(.roundedBorder).disabled(receiver.active)
                .onSubmit { receiver.updateHost(host) }
            HStack {
                Button("保存地址") { receiver.updateHost(host) }.disabled(receiver.active)
                Spacer()
                Button("复制配对链接") {
                    guard let url = receiver.pairing?.url else { return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }.disabled(receiver.pairing?.url == nil)
            }
        }.padding(24).frame(width: 300).background(Color.white)
            .foregroundStyle(MicAppearance.ink).tint(MicAppearance.blue).preferredColorScheme(.light)
    }
    func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output.transformed(by: .init(scaleX: 6, y: 6)), from: output.extent.applying(.init(scaleX: 6, y: 6))) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 180, height: 180))
    }
}
@main struct RemoteMicMac: App {
    @StateObject var receiver = Receiver()
    var body: some Scene {
        WindowGroup(MicAppearance.name) { ReceiverView(receiver: receiver).onAppear {
            if let path = ProcessInfo.processInfo.environment["REMOTE_MIC_PAIR_EXPORT"], let pairing = receiver.pairing, let data = try? JSONEncoder().encode(pairing) {
                FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        } }.windowResizability(.contentSize).windowStyle(.hiddenTitleBar)
    }
}
