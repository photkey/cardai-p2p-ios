import Foundation

/// camstream/1 线协议：与 Windows `streaming/camstream.py`、Android `Protocol.kt` 逐字节一致。
public enum Wire {
    public static let alpn = "cardai/camstream/1"
    public static let alpnData = Data(alpn.utf8)
    public static let version: UInt8 = 1
    public static let maxControlFrame = 1_048_576
    public static let groupHeaderFixed = 18
    public static let magic: [UInt8] = [0x43, 0x53, 0x47, 0x31] // "CSG1"
    public static let flagKeyframe: UInt8 = 0x01
    public static let flagEpochStart: UInt8 = 0x02

    public static let defaultWidth = 1280
    public static let defaultHeight = 720
    public static let defaultFPS = 30
    public static let defaultGOP = 15
    public static let defaultBitrateBps = 2_000_000
    public static let defaultEpoch: UInt32 = 1
    public static let timescale: Int64 = 90_000

    public enum Error: Swift.Error, CustomStringConvertible {
        case invalid(String)
        public var description: String {
            switch self {
            case .invalid(let message): return message
            }
        }
    }

    public struct GroupHeader: Equatable {
        public let flags: UInt8
        public let epoch: UInt32
        public let groupSeq: UInt32
        public let frameCount: UInt16
        public let config: Data
        public let headerLen: Int
        public var keyframe: Bool { flags & Wire.flagKeyframe != 0 }
        public var epochStart: Bool { flags & Wire.flagEpochStart != 0 }
    }

    public struct FrameHeader: Equatable {
        public let frameLen: UInt32
        public let frameId: UInt32
        public let captureUtcUs: Int64
    }

    // MARK: - 控制帧

    public static func packControl(_ object: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: object, options: [])
        guard payload.count <= maxControlFrame else {
            throw Error.invalid("控制帧 \(payload.count) 字节超过上限 \(maxControlFrame)")
        }
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    public static func unpackControl(_ frame: Data) throws -> [String: Any] {
        guard frame.count >= 4 else {
            throw Error.invalid("控制帧头被截断：\(frame.count) 字节")
        }
        let length = Int(readUInt32(frame, 0))
        guard length <= maxControlFrame else {
            throw Error.invalid("控制帧 \(length) 字节超过上限 \(maxControlFrame)")
        }
        guard length == frame.count - 4 else {
            throw Error.invalid("控制帧长度不符：声明 \(length)，实际 \(frame.count - 4)")
        }
        let payload = frame.subdata(in: 4..<(4 + length))
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw Error.invalid("控制帧 JSON 顶层必须是对象")
        }
        return object
    }

    // MARK: - 媒体组

    public static func packGroupHeader(flags: UInt8, epoch: UInt32, groupSeq: UInt32,
        frameCount: UInt16, config: Data = Data()) throws -> Data {
        guard config.count <= 0xFFFF else {
            throw Error.invalid("组头 config 过长：\(config.count)")
        }
        var data = Data(magic)
        data.append(version)
        data.append(flags)
        data.append(contentsOf: be32(epoch))
        data.append(contentsOf: be32(groupSeq))
        data.append(contentsOf: be16(frameCount))
        data.append(contentsOf: be16(UInt16(config.count)))
        data.append(config)
        return data
    }

    public static func unpackGroupHeader(_ data: Data) throws -> GroupHeader {
        guard data.count >= groupHeaderFixed else {
            throw Error.invalid("组头被截断：\(data.count) 字节")
        }
        let bytes = [UInt8](data.prefix(groupHeaderFixed))
        guard Array(bytes[0..<4]) == magic else {
            throw Error.invalid("组头 magic 非法")
        }
        guard bytes[4] == version else {
            throw Error.invalid("组头版本不支持：\(bytes[4])")
        }
        let epoch = readUInt32(data, 6)
        let groupSeq = readUInt32(data, 10)
        let frameCount = readUInt16(data, 14)
        let configLen = Int(readUInt16(data, 16))
        let headerLen = groupHeaderFixed + configLen
        guard data.count >= headerLen else {
            throw Error.invalid("组头 config 被截断：声明 \(configLen)")
        }
        let config = data.subdata(in: groupHeaderFixed..<headerLen)
        return GroupHeader(flags: bytes[5], epoch: epoch, groupSeq: groupSeq,
            frameCount: frameCount, config: config, headerLen: headerLen)
    }

    public static func packFrameHeader(frameLen: UInt32, frameId: UInt32,
        captureUtcUs: Int64) -> Data {
        var data = Data()
        data.append(contentsOf: be32(frameLen))
        data.append(contentsOf: be32(frameId))
        var value = captureUtcUs.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        return data
    }

    public static func unpackFrameHeader(_ data: Data) throws -> FrameHeader {
        guard data.count >= 16 else {
            throw Error.invalid("帧头被截断：\(data.count) 字节")
        }
        return FrameHeader(frameLen: readUInt32(data, 0), frameId: readUInt32(data, 4),
            captureUtcUs: readInt64(data, 8))
    }

    // MARK: - HEVC Annex-B

    public static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count, bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }
        var nals: [Data] = []
        for (position, start) in starts.enumerated() {
            let bodyStart = start.0 + start.1
            let bodyEnd = position + 1 < starts.count ? starts[position + 1].0 : bytes.count
            guard bodyEnd > bodyStart else { continue }
            var last = bodyEnd
            while last > bodyStart, bytes[last - 1] == 0 { last -= 1 }
            guard last > bodyStart else { continue }
            nals.append(data.subdata(in: bodyStart..<last))
        }
        return nals
    }

    public static func nalType(_ nal: Data) -> UInt8 {
        guard let first = nal.first else { return 0 }
        return (first >> 1) & 0x3F
    }

    public static func isIDRAccessUnit(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var position = 0
        while position + 3 <= bytes.count {
            guard bytes[position] == 0, bytes[position + 1] == 0,
                  bytes[position + 2] == 1 else {
                position += 1
                continue
            }
            let start = position + 3
            guard start < bytes.count else { return false }
            let type = (bytes[start] >> 1) & 0x3F
            if type <= 31 {
                return type == 19 || type == 20 || type == 21
            }
            position = start
        }
        return false
    }

    public static func parameterSets(_ config: Data) -> Data {
        var found: [UInt8: Data] = [:]
        for nal in splitAnnexB(config) {
            let type = nalType(nal)
            if (type == 32 || type == 33 || type == 34) && found[type] == nil {
                found[type] = nal
            }
        }
        var output = Data()
        for type: UInt8 in [32, 33, 34] {
            guard let nal = found[type] else { continue }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(nal)
        }
        return output
    }

    /// AVCC（4 字节长度前缀 NAL）转 Annex-B；VTCompressionSession 输出为 AVCC。
    public static func annexB(fromAVCC data: Data, lengthSize: Int = 4) -> Data {
        let bytes = [UInt8](data)
        var offset = 0
        var output = Data()
        while offset + lengthSize <= bytes.count {
            var length = 0
            for index in 0..<lengthSize {
                length = (length << 8) | Int(bytes[offset + index])
            }
            guard length > 0, offset + lengthSize + length <= bytes.count else { break }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(contentsOf: bytes[(offset + lengthSize)..<(offset + lengthSize + length)])
            offset += lengthSize + length
        }
        return output
    }

    // MARK: - 字节工具

    public static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    public static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        let bytes = [UInt8](data[offset..<(offset + 2)])
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let bytes = [UInt8](data[offset..<(offset + 4)])
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    static func readInt64(_ data: Data, _ offset: Int) -> Int64 {
        var value: Int64 = 0
        for index in 0..<8 {
            value = (value << 8) | Int64([UInt8](data[(offset + index)..<(offset + index + 1)])[0])
        }
        return value
    }
}

/// 控制消息类型（Sendable，用于跨 actor 传递）。
public enum ControlMessage: Sendable {
    case welcome(sessionId: String, serverUtcUs: Int64, heartbeatMs: Int)
    case selectProfile(width: Int, height: Int, fps: Int, gop: Int, bitrateBps: Int,
        epoch: UInt32, requestIdr: Bool)
    case setPolicy(mode: String, maxBufferBytes: Int64, maxAgeMs: Int, requestIdr: Bool)
    case groupAck(epoch: UInt32, groupSeq: UInt32, accepted: Bool, reason: String)
    case timeReply(seq: Int, t1Us: Int64, t2Us: Int64, t3Us: Int64)
    case error(code: String, message: String)
    case stop(reason: String)
    case other(String)

    public static func parse(_ dict: [String: Any]) -> ControlMessage {
        let type = dict["type"] as? String ?? ""
        func int(_ key: String, _ fallback: Int = 0) -> Int {
            (dict[key] as? NSNumber)?.intValue ?? fallback
        }
        func int64(_ key: String, _ fallback: Int64 = 0) -> Int64 {
            (dict[key] as? NSNumber)?.int64Value ?? fallback
        }
        switch type {
        case "welcome":
            return .welcome(sessionId: dict["session_id"] as? String ?? "",
                serverUtcUs: int64("server_utc_us"), heartbeatMs: int("heartbeat_ms", 1000))
        case "select_profile":
            return .selectProfile(width: int("width", Wire.defaultWidth),
                height: int("height", Wire.defaultHeight), fps: int("fps", Wire.defaultFPS),
                gop: int("gop", Wire.defaultGOP),
                bitrateBps: int("bitrate_bps", Wire.defaultBitrateBps),
                epoch: UInt32(max(0, int("epoch", Int(Wire.defaultEpoch)))),
                requestIdr: dict["request_idr"] as? Bool ?? true)
        case "set_policy":
            return .setPolicy(mode: dict["mode"] as? String ?? "realtime",
                maxBufferBytes: int64("max_buffer_bytes", 32 * 1024 * 1024),
                maxAgeMs: int("max_age_ms", 0),
                requestIdr: dict["request_idr"] as? Bool ?? false)
        case "group_ack":
            return .groupAck(epoch: UInt32(max(0, int("epoch"))),
                groupSeq: UInt32(max(0, int("group_seq"))),
                accepted: dict["accepted"] as? Bool ?? false,
                reason: dict["reason"] as? String ?? "")
        case "time_reply":
            return .timeReply(seq: int("seq"), t1Us: int64("t1_us"),
                t2Us: int64("t2_us"), t3Us: int64("t3_us"))
        case "error":
            return .error(code: dict["code"] as? String ?? "INTERNAL",
                message: dict["message"] as? String ?? "")
        case "stop":
            return .stop(reason: dict["reason"] as? String ?? "")
        default:
            return .other(type)
        }
    }
}
