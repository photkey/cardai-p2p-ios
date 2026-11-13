import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = CollectorModel()
    @State private var ticket = ""
    @State private var room = "101"
    @State private var token = ""
    @State private var address = ""
    @State private var showScanner = false

    var body: some View {
        VStack(spacing: 10) {
            CameraPreviewView(session: model.session)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(model.status).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Text(model.statsText).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("ticket", text: $ticket)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("房间号", text: $room).textFieldStyle(.roundedBorder)
            TextField("token", text: $token)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("端点地址（扫码自动填）", text: $address)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            HStack {
                Button("扫描二维码") { showScanner = true }
                Button("连接") {
                    model.connect(ticket: ticket, room: room, token: token, addr: address)
                }
                .disabled(ticket.isEmpty || token.isEmpty)
                Spacer()
                Button(model.capturing ? "停止" : "开始") {
                    if model.capturing { model.stopCapture() } else { model.startCapture() }
                }
                .disabled(!model.connected)
            }
        }
        .padding()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                showScanner = false
                applyPairingURI(code)
            }
        }
    }

    private func applyPairingURI(_ code: String) {
        guard let components = URLComponents(string: code),
              components.scheme == "cardai", components.host == "pair" else { return }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let value = value("ticket") { ticket = value }
        if let value = value("room") { room = value }
        if let value = value("token") { token = value }
        if let value = value("addr") { address = value }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
