import Foundation

struct PendingGroup: Sendable {
    let epoch: UInt32
    let groupSeq: UInt32
    let frames: [EncodedFrame]
    let config: Data
}

/// reliable：保留到 group_ack；realtime：在途字节超限丢弃最旧组。
actor GopSender {
    private let client: IrohClient
    private let onOverflow: @Sendable (String) -> Void
    private(set) var mode: String = "realtime"
    private(set) var maxBufferBytes: Int64 = 32 * 1024 * 1024
    private(set) var droppedGroups: Int64 = 0
    private var reliable: [UInt32: Int64] = [:]
    private var reliableBytes: Int64 = 0
    private var inFlightBytes: Int64 = 0

    init(client: IrohClient, onOverflow: @escaping @Sendable (String) -> Void) {
        self.client = client
        self.onOverflow = onOverflow
    }

    func setPolicy(_ message: ControlMessage) {
        guard case .setPolicy(let requested, let maxBytes, _, let requestIdr) = message else {
            return
        }
        mode = requested == "reliable" ? "reliable" : "realtime"
        maxBufferBytes = max(1_048_576, maxBytes)
        if mode == "realtime" {
            reliable.removeAll()
            reliableBytes = 0
        }
        if requestIdr {
            syncRequester?()
        }
    }

    private var syncRequester: (@Sendable () -> Void)?

    func setSyncRequester(_ requester: @escaping @Sendable () -> Void) {
        syncRequester = requester
    }

    func onAck(epoch: UInt32, groupSeq: UInt32, accepted: Bool) {
        guard let bytes = reliable.removeValue(forKey: groupSeq) else { return }
        reliableBytes -= bytes
        if !accepted { syncRequester?() }
    }

    func send(_ group: PendingGroup) async {
        let bytes = group.frames.reduce(Int64(0)) { $0 + 16 + Int64($1.data.count) }
        if mode == "reliable" {
            guard reliableBytes + bytes <= maxBufferBytes else {
                onOverflow("BUFFER_OVERFLOW")
                return
            }
            reliable[group.groupSeq] = bytes
            reliableBytes += bytes
        } else {
            guard inFlightBytes + bytes <= maxBufferBytes else {
                droppedGroups += 1
                return
            }
        }
        inFlightBytes += bytes
        do {
            try await client.sendGroup(epoch: group.epoch, groupSeq: group.groupSeq,
                frames: group.frames, config: group.config)
        } catch {
            droppedGroups += 1
        }
        inFlightBytes -= bytes
    }

    func bufferBytes() -> Int64 {
        mode == "reliable" ? reliableBytes : inFlightBytes
    }

    func pendingGroups() -> Int {
        reliable.count
    }
}

/// 填组装：只从 keyframe 起组；keyframe 到达时交出上一组。
final class GopAssembler: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [EncodedFrame] = []
    private(set) var droppedFrames: Int64 = 0

    func add(_ frame: EncodedFrame) -> [EncodedFrame]? {
        lock.withLock {
            if frame.keyframe {
                let previous = frames.isEmpty ? nil : frames
                frames = [frame]
                return previous
            }
            if frames.isEmpty {
                droppedFrames += 1
                return nil
            }
            frames.append(frame)
            return nil
        }
    }

    func flush() -> [EncodedFrame]? {
        lock.withLock {
            guard !frames.isEmpty else { return nil }
            let group = frames
            frames = []
            return group
        }
    }

    func currentSize() -> Int {
        lock.withLock { frames.count }
    }
}
