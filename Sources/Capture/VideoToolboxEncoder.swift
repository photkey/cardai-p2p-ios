import CoreMedia
import Foundation
import VideoToolbox

struct EncodedFrame: Sendable {
    let frameId: UInt32
    let captureUtcUs: Int64
    let keyframe: Bool
    let data: Data
}

/// HEVC 硬编：VTCompressionSession 实时、无 B 帧，输出 AVCC 转 Annex-B。
final class VideoToolboxEncoder: @unchecked Sendable {
    private let width: Int
    private let height: Int
    private let profile: VideoProfile
    private let clock: ClockSync
    private let onFrame: @Sendable (EncodedFrame) -> Void
    private let onFormat: @Sendable (Data, Int, Int) -> Void
    private let onError: @Sendable (String) -> Void

    private var session: VTCompressionSession?
    private var frameId: UInt32 = 0
    private var framesSinceKey = 0
    private var config = Data()
    private let stateLock = NSLock()
    private var ptsMap: [Int64: Int64] = [:]
    private var forceNextKeyframe = false

    init(width: Int, height: Int, profile: VideoProfile, clock: ClockSync,
         onFrame: @escaping @Sendable (EncodedFrame) -> Void,
         onFormat: @escaping @Sendable (Data, Int, Int) -> Void,
         onError: @escaping @Sendable (String) -> Void) {
        self.width = width
        self.height = height
        self.profile = profile
        self.clock = clock
        self.onFrame = onFrame
        self.onFormat = onFormat
        self.onError = onError
    }

    func start() -> Bool {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: videoToolboxOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created)
        guard status == noErr, let created else {
            onError("ENCODER_ERROR:VTCompressionSessionCreate \(status)")
            return false
        }
        session = created
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: profile.gop))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: VideoProfile.bitrateFor(width: width, height: height,
                fps: profile.fps)))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTCompressionSessionPrepareToEncodeFrames(created)
        return true
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostUs = CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value
        let utcUs = clock.utcFromHost(hostUs)
        stateLock.withLock {
            ptsMap[hostUs] = utcUs
            if ptsMap.count > 64 {
                ptsMap.removeValue(forKey: ptsMap.keys.min() ?? hostUs)
            }
        }
        var flags: VTEncodeInfoFlags = []
        let force = stateLock.withLock { () -> Bool in
            let value = forceNextKeyframe
            forceNextKeyframe = false
            return value
        }
        let frameProperties: CFDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
            presentationTimeStamp: pts, duration: .invalid,
            frameProperties: frameProperties, sourceFrameRefcon: nil,
            infoFlagsOut: &flags)
        if status != noErr {
            onError("ENCODER_ERROR:EncodeFrame \(status)")
        }
    }

    func requestKeyframe() {
        guard session != nil else { return }
        stateLock.withLock { forceNextKeyframe = true }
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    fileprivate func handle(_ status: OSStatus, _ infoFlags: VTEncodeInfoFlags,
        _ sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer else {
            if status != noErr { onError("ENCODER_ERROR:callback \(status)") }
            return
        }
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            updateConfigIfNeeded(format)
        }
        let keyframe = isKeyframe(sampleBuffer)
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let result = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard result == kCMBlockBufferNoErr, let dataPointer, length > 0 else { return }
        let avcc = Data(bytes: dataPointer, count: length)
        let annexB = Wire.annexB(fromAVCC: avcc)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostUs = CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value
        let utcUs = stateLock.withLock { ptsMap[hostUs] } ?? clock.utcFromHost(hostUs)
        let frame = EncodedFrame(frameId: frameId, captureUtcUs: utcUs,
            keyframe: keyframe, data: annexB)
        frameId &+= 1
        if keyframe {
            framesSinceKey = 0
        } else {
            framesSinceKey += 1
        }
        onFrame(frame)
    }

    private func updateConfigIfNeeded(_ format: CMVideoFormatDescription) {
        guard config.isEmpty else { return }
        var count = 0
        var nalLength: Int32 = 4
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
        guard count > 0 else { return }
        var parameters = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format,
                parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer, size > 0 else { continue }
            parameters.append(contentsOf: [0, 0, 0, 1])
            parameters.append(pointer, count: size)
        }
        guard !parameters.isEmpty else { return }
        config = Wire.parameterSets(parameters)
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        onFormat(config, Int(dims.width), Int(dims.height))
    }

    private func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
            createIfNecessary: false) as? [[CFString: Any]],
            let first = attachments.first else { return true }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    var parameterSets: Data { stateLock.withLock { config } }
}

private func videoToolboxOutputCallback(_ outputCallbackRefCon: UnsafeMutableRawPointer?,
    _ sourceFrameRefCon: UnsafeMutableRawPointer?, _ status: OSStatus,
    _ infoFlags: VTEncodeInfoFlags, _ sampleBuffer: CMSampleBuffer?) {
    guard let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<VideoToolboxEncoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handle(status, infoFlags, sampleBuffer)
}
