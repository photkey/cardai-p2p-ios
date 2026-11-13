import AVFoundation
import CoreMedia
import Foundation

/// AVFoundation 采集：1280x720@30 优先，BGRA420 双平面输出，VideoToolbox 硬编。
final class CaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
        @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cardai.camera.video")
    private let clock: ClockSync
    private let onFrame: @Sendable (EncodedFrame) -> Void
    private let onFormat: @Sendable (Data, Int, Int) -> Void
    private let onError: @Sendable (String) -> Void
    private var encoder: VideoToolboxEncoder?
    private var profile = VideoProfile.default
    private var running = false

    init(clock: ClockSync,
         onFrame: @escaping @Sendable (EncodedFrame) -> Void,
         onFormat: @escaping @Sendable (Data, Int, Int) -> Void,
         onError: @escaping @Sendable (String) -> Void) {
        self.clock = clock
        self.onFrame = onFrame
        self.onFormat = onFormat
        self.onError = onError
    }

    func start(profile: VideoProfile) -> Bool {
        guard !running else { return true }
        self.profile = profile
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
            position: .back) else {
            onError("CAMERA_ERROR:no back camera")
            return false
        }
        do {
            let format = try selectFormat(device, target: profile)
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(profile.fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()

            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                onError("CAMERA_ERROR:无法添加相机输入")
                session.commitConfiguration()
                return false
            }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                onError("CAMERA_ERROR:无法添加视频输出")
                session.commitConfiguration()
                return false
            }
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()
            running = true
            return true
        } catch {
            onError("CAMERA_ERROR:\(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        guard running else { return }
        running = false
        session.stopRunning()
        session.beginConfiguration()
        for output in session.outputs { session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
        encoder?.stop()
        encoder = nil
    }

    func requestKeyframe() {
        encoder?.requestKeyframe()
    }

    func captureOutput(_ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running else { return }
        if encoder == nil {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                return
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            let created = VideoToolboxEncoder(width: Int(dimensions.width),
                height: Int(dimensions.height), profile: profile, clock: clock,
                onFrame: onFrame, onFormat: onFormat, onError: onError)
            guard created.start() else { return }
            encoder = created
        }
        encoder?.encode(sampleBuffer)
    }

    private func selectFormat(_ device: AVCaptureDevice,
        target: VideoProfile) throws -> AVCaptureDevice.Format {
        let wanted = CGSize(width: target.width, height: target.height)
        let candidates = device.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains {
                Double(target.fps) >= $0.minFrameRate && Double(target.fps) <= $0.maxFrameRate
            }
        }
        guard let best = candidates.min(by: { lhs, rhs in
            score(lhs, wanted) < score(rhs, wanted)
        }) else {
            throw Wire.Error.invalid("没有支持 \(target.fps)fps 的相机格式")
        }
        return best
    }

    private func score(_ format: AVCaptureDevice.Format, _ wanted: CGSize) -> Int {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return abs(Int(dimensions.width) - Int(wanted.width))
            + abs(Int(dimensions.height) - Int(wanted.height))
    }
}
