import AVFoundation
import Foundation
import UIKit

@MainActor
final class CollectorModel: ObservableObject {
    @Published var status = "未连接"
    @Published var statsText = "--"
    @Published var capturing = false
    @Published var connected = false

    let session = AVCaptureSession()
    private let clock = ClockSync()
    private var client: IrohClient?
    private var sender: GopSender?
    private var pipeline: CapturePipeline?
    private var capture: CaptureController?
    private var profile = VideoProfile.default
    private var statsTask: Task<Void, Never>?
    private let deviceId: String
    private let appVersion = "1.0.0"

    init() {
        let key = "cardai.device_id"
        if let saved = UserDefaults.standard.string(forKey: key) {
            deviceId = saved
        } else {
            let generated = "ios-" + UUID().uuidString
            UserDefaults.standard.set(generated, forKey: key)
            deviceId = generated
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    func connect(ticket: String, room: String, token: String, addr: String) {
        if let old = client {
            Task { await old.close() }
        }
        let client = IrohClient { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.client = client
        status = "连接中…"
        Task {
            do {
                try await client.connect(ticket: ticket, addressSpec: addr, room: room,
                    token: token, deviceId: deviceId, appVersion: appVersion)
            } catch {
                status = "连接失败：\(error)"
            }
        }
    }

    private func handle(_ event: ClientEvent) {
        switch event {
        case .connected:
            connected = true
            status = "已连接"
            startClockProbes()
        case .message(let message):
            handle(message)
        case .disconnected(let reason):
            connected = false
            status = "连接断开：\(reason)"
            stopCapture()
        }
    }

    private func handle(_ message: ControlMessage) {
        switch message {
        case .welcome(let sessionId, _, _):
            status = "已连接：\(sessionId)"
        case .selectProfile(let width, let height, let fps, let gop, let bitrate, let epoch,
                _):
            guard let parsed = VideoProfile.fromSelectProfile(width: width, height: height,
                fps: fps, gop: gop, bitrateBps: bitrate, epoch: epoch) else {
                sendUnsupportedProfile(fps: fps)
                return
            }
            let restart = capturing && (parsed.fps != profile.fps || parsed.width != profile.width)
            profile = parsed
            if restart {
                stopCapture()
                startCapture()
            }
        case .setPolicy:
            Task { await sender?.setPolicy(message) }
        case .groupAck(let epoch, let groupSeq, let accepted, _):
            Task { await sender?.onAck(epoch: epoch, groupSeq: groupSeq, accepted: accepted) }
        case .timeReply(let seq, let t1, let t2, let t3):
            clock.onReply(seq: seq, t1Us: t1, t2Us: t2, t3Us: t3)
        case .error(let code, let message):
            status = "\(code): \(message)"
        case .stop:
            stopCapture()
        case .other:
            break
        }
    }

    private func sendUnsupportedProfile(fps: Int) {
        status = "UNSUPPORTED_PROFILE fps=\(fps)"
        guard let client else { return }
        Task {
            try? await client.sendError(code: "UNSUPPORTED_PROFILE",
                message: "fps=\(fps) 不支持")
        }
    }

    private func startClockProbes() {
        guard let client else { return }
        Task {
            for seq in 0..<4 {
                try? await client.sendTimeProbe(seq: seq, t1Us: ClockSync.wallNowUs())
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    func startCapture() {
        guard let client else { return }
        let sender = GopSender(client: client) { [weak self] code in
            Task { @MainActor in self?.status = code }
            Task { try? await client.sendError(code: code, message: "buffer overflow") }
        }
        self.sender = sender
        let pipeline = CapturePipeline(deviceId: deviceId, profile: profile,
            sender: sender, client: client) { [weak self] message in
            Task { @MainActor in self?.status = message }
        }
        let capture = CaptureController(clock: clock,
            onFrame: { frame in pipeline.onFrame(frame) },
            onFormat: { config, width, height in
                pipeline.onFormat(config: config, width: width, height: height)
            },
            onError: { [weak self] message in
                Task { @MainActor in
                    self?.status = message
                    self?.stopCapture()
                }
            })
        guard capture.start(profile: profile) else { return }
        self.pipeline = pipeline
        self.capture = capture
        capturing = true
        Task {
            await sender.setSyncRequester { [weak capture] in
                capture?.requestKeyframe()
            }
        }
        startStats()
    }

    func stopCapture() {
        guard capturing else { return }
        capturing = false
        statsTask?.cancel()
        statsTask = nil
        capture?.stop()
        capture = nil
        if let pipeline {
            pipeline.flush()
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                pipeline.stop()
            }
        }
        pipeline = nil
    }

    private func startStats() {
        statsTask?.cancel()
        guard let client, let pipeline else { return }
        statsTask = Task {
            var lastFrames: Int64 = 0
            var lastBytes: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let snapshot = pipeline.snapshot()
                let fps = Int(snapshot.frameCount - lastFrames)
                let bitrate = (snapshot.byteCount - lastBytes) * 8
                lastFrames = snapshot.frameCount
                lastBytes = snapshot.byteCount
                let battery = Int(UIDevice.current.batteryLevel * 100)
                try? await client.sendStats(fps: fps, bitrateBps: bitrate,
                    bufferBytes: 0, droppedGroups: snapshot.droppedGroups,
                    thermal: Self.thermalStatus(), battery: battery, rttUs: 0)
                statsText = "fps=\(fps) \(snapshot.width)x\(snapshot.height) "
                    + "bitrate=\(bitrate) drop=\(snapshot.droppedFrames)"
            }
        }
    }

    private static func thermalStatus() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "light"
        case .serious: return "moderate"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }
}
