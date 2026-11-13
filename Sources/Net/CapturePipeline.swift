import Foundation

struct PipelineStats: Sendable {
    var frameCount: Int64
    var byteCount: Int64
    var width: Int
    var height: Int
    var configBytes: Int
    var droppedGroups: Int64
    var droppedFrames: Int64
}

/// 编码帧 → 组装配 → 有顺序地串行发送。VT 回调只入队，发送在 AsyncStream 消费者里执行。
final class CapturePipeline: @unchecked Sendable {
    private let deviceId: String
    private let profile: VideoProfile
    private let sender: GopSender
    private let client: IrohClient
    private let assembler = GopAssembler()
    private let lock = NSLock()
    private var config = Data()
    private var width = 0
    private var height = 0
    private var frameCount: Int64 = 0
    private var byteCount: Int64 = 0
    private var groupSeq: UInt32 = 0
    private var catalogSent = false
    private var continuation: AsyncStream<PendingGroup>.Continuation?
    private var consumer: Task<Void, Never>?
    private let onError: @Sendable (String) -> Void

    init(deviceId: String, profile: VideoProfile, sender: GopSender,
         client: IrohClient, onError: @escaping @Sendable (String) -> Void) {
        self.deviceId = deviceId
        self.profile = profile
        self.sender = sender
        self.client = client
        self.onError = onError
        let (stream, continuation) = AsyncStream<PendingGroup>.makeStream()
        self.continuation = continuation
        self.consumer = Task { [sender] in
            for await group in stream {
                await sender.send(group)
            }
        }
    }

    func onFrame(_ frame: EncodedFrame) {
        lock.withLock {
            frameCount += 1
            byteCount += Int64(frame.data.count)
        }
        guard let group = assembler.add(frame) else { return }
        enqueue(group)
    }

    func onFormat(config: Data, width: Int, height: Int) {
        let sendCatalog: Bool = lock.withLock {
            self.config = config
            self.width = width
            self.height = height
            guard !catalogSent, !config.isEmpty else { return false }
            catalogSent = true
            return true
        }
        guard sendCatalog else { return }
        let epoch = profile.epoch
        let fps = profile.fps
        let gop = profile.gop
        Task { [client] in
            try? await client.sendCatalog(deviceId: deviceId, epoch: epoch,
                width: width, height: height, fps: fps, gop: gop,
                timestampSource: "camera_pts", config: config)
        }
    }

    func flush() {
        if let group = assembler.flush() {
            enqueue(group)
        }
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        consumer?.cancel()
        consumer = nil
    }

    func snapshot() -> PipelineStats {
        lock.withLock {
            PipelineStats(frameCount: frameCount, byteCount: byteCount, width: width,
                height: height, configBytes: config.count,
                droppedGroups: 0, droppedFrames: assembler.droppedFrames)
        }
    }

    func epoch() -> UInt32 { profile.epoch }

    private func enqueue(_ frames: [EncodedFrame]) {
        guard !frames.isEmpty else { return }
        let (seq, configSnapshot): (UInt32, Data) = lock.withLock {
            let value = groupSeq
            groupSeq += 1
            return (value, config)
        }
        continuation?.yield(PendingGroup(epoch: profile.epoch, groupSeq: seq,
            frames: frames, config: configSnapshot))
    }
}
