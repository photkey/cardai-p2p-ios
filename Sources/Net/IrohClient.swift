import Foundation
import IrohLib

enum ClientEvent: Sendable {
    case connected
    case message(ControlMessage)
    case disconnected(String)
}

/// iroh 拨号端：绑定端点、hello/welcome/select_profile，控制读循环独立 Task。
/// 所有方法走 actor 串行化，控制写与组发送不会交错。
actor IrohClient {
    private var endpoint: Endpoint?
    private var connection: Connection?
    private var controlSend: SendStream?
    private var readerTask: Task<Void, Never>?
    private let onEvent: @Sendable (ClientEvent) -> Void
    private(set) var lastAckedGroupSeq: UInt32 = 0

    init(onEvent: @escaping @Sendable (ClientEvent) -> Void) {
        self.onEvent = onEvent
    }

    func connect(ticket: String, addressSpec: String, room: String, token: String,
        deviceId: String, appVersion: String, resume: Bool = false) async throws {
        var options = EndpointOptions()
        options.alpns = [Wire.alpnData]
        let bound = try await Endpoint.bind(options: options)
        endpoint = bound
        let target: EndpointAddr
        if !addressSpec.isEmpty {
            target = try Self.parseAddressSpec(addressSpec)
        } else {
            target = try EndpointTicket.fromString(str: ticket).endpointAddr()
        }
        let conn = try await bound.connect(addr: target, alpn: Wire.alpnData)
        connection = conn
        let stream = try await conn.openBi()
        let recv = stream.recv()
        controlSend = stream.send()
        let hello = Self.helloMessage(deviceId: deviceId, appVersion: appVersion,
            room: room, token: token, resume: resume,
            lastAckedGroupSeq: lastAckedGroupSeq)
        try await stream.send().writeAll(buf: try Wire.packControl(hello))
        let welcome = try await Self.readControl(recv)
        if case .error(let code, let message) = welcome {
            throw Wire.Error.invalid("\(code): \(message)")
        }
        onEvent(.message(welcome))
        let profile = try await Self.readControl(recv)
        onEvent(.message(profile))
        onEvent(.connected)
        readerTask = Task { [weak self] in
            await self?.controlLoop(recv)
        }
    }

    private func controlLoop(_ recv: RecvStream) async {
        while !Task.isCancelled {
            do {
                let message = try await Self.readControl(recv)
                onEvent(.message(message))
                if case .stop(let reason) = message {
                    onEvent(.disconnected(reason))
                    return
                }
            } catch {
                onEvent(.disconnected(String(describing: error)))
                return
            }
        }
    }

    func sendControlFrame(_ frame: Data) async throws {
        guard let send = controlSend else { return }
        try await send.writeAll(buf: frame)
    }

    func sendTimeProbe(seq: Int, t1Us: Int64) async throws {
        try await sendControl(["type": "time_probe", "seq": seq, "t1_us": t1Us])
    }

    func sendCatalog(deviceId: String, epoch: UInt32, width: Int, height: Int, fps: Int,
        gop: Int, timestampSource: String, config: Data) async throws {
        try await sendControl([
            "type": "catalog", "device_id": deviceId, "epoch": Int(epoch),
            "width": width, "height": height, "fps": fps, "gop": gop,
            "codec": "hevc", "timescale": 90_000,
            "timestamp_source": timestampSource,
            "config_b64": config.base64EncodedString(),
        ])
    }

    func sendError(code: String, message: String) async throws {
        try await sendControl(["type": "error", "code": code, "message": message])
    }

    func sendStats(fps: Int, bitrateBps: Int64, bufferBytes: Int64, droppedGroups: Int64,
        thermal: String, battery: Int, rttUs: Int64) async throws {
        try await sendControl([
            "type": "stats", "fps": fps, "bitrate_bps": bitrateBps,
            "buffer_bytes": bufferBytes, "dropped_groups": droppedGroups,
            "thermal": thermal, "battery": battery, "rtt_us": rttUs,
        ])
    }

    func sendGroup(epoch: UInt32, groupSeq: UInt32, frames: [EncodedFrame],
        config: Data) async throws {
        guard let conn = connection, let first = frames.first else { return }
        var flags: UInt8 = first.keyframe ? Wire.flagKeyframe : 0
        if groupSeq == 0 { flags |= Wire.flagEpochStart }
        let header = try Wire.packGroupHeader(flags: flags, epoch: epoch,
            groupSeq: groupSeq, frameCount: UInt16(frames.count),
            config: groupSeq == 0 ? Wire.parameterSets(config) : Data())
        var payload = Data()
        payload.append(header)
        for frame in frames {
            payload.append(Wire.packFrameHeader(frameLen: UInt32(frame.data.count),
                frameId: frame.frameId, captureUtcUs: frame.captureUtcUs))
            payload.append(frame.data)
        }
        let stream = try await conn.openBi()
        let send = stream.send()
        try await send.writeAll(buf: payload)
        try await send.finish()
    }

    func close() async {
        readerTask?.cancel()
        readerTask = nil
        controlSend = nil
        connection = nil
        if let endpoint {
            try? await endpoint.close()
        }
        endpoint = nil
    }

    private func sendControl(_ object: [String: Any]) async throws {
        guard let send = controlSend else { return }
        try await send.writeAll(buf: try Wire.packControl(object))
    }

    private static func readControl(_ recv: RecvStream) async throws -> ControlMessage {
        let head = try await recv.readExact(size: 4)
        guard head.count == 4 else {
            throw Wire.Error.invalid("控制帧头被截断")
        }
        let bytes = [UInt8](head)
        let length = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        guard length <= UInt32(Wire.maxControlFrame) else {
            throw Wire.Error.invalid("控制帧超限：\(length)")
        }
        let payload = length == 0 ? Data() : try await recv.readExact(size: length)
        var frame = head
        frame.append(payload)
        return ControlMessage.parse(try Wire.unpackControl(frame))
    }

    private static func parseAddressSpec(_ spec: String) throws -> EndpointAddr {
        guard let separator = spec.firstIndex(of: "@") else {
            throw Wire.Error.invalid("端点地址缺少 @：\(spec)")
        }
        let id = try EndpointId.fromString(s: String(spec[spec.startIndex..<separator]))
        let addresses = String(spec[spec.index(after: separator)...])
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !addresses.isEmpty else {
            throw Wire.Error.invalid("端点地址没有直连地址：\(spec)")
        }
        return EndpointAddr(id: id, relayUrl: nil, addresses: addresses)
    }

    private static func helloMessage(deviceId: String, appVersion: String, room: String,
        token: String, resume: Bool, lastAckedGroupSeq: UInt32) -> [String: Any] {
        let capabilities: [String: Any] = [
            "profiles": [["width": Wire.defaultWidth, "height": Wire.defaultHeight,
                          "fps": Wire.defaultFPS]],
            "encoder": "hevc",
            "timestamp_source": "camera_pts",
            "battery": 0,
            "thermal": "nominal",
        ]
        var hello: [String: Any] = [
            "type": "hello", "device_id": deviceId, "platform": "ios",
            "app_version": appVersion, "room": room, "token": token,
            "capabilities": capabilities,
        ]
        if resume {
            hello["resume"] = true
            hello["last_acked_group_seq"] = Int(lastAckedGroupSeq)
        }
        return hello
    }
}
