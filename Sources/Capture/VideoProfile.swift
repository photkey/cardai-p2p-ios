import Foundation

/// 一路采集档位；实际分辨率以 AVFoundation 选定 format 为准。
struct VideoProfile: Sendable, Equatable {
    var width: Int
    var height: Int
    var fps: Int
    var gop: Int
    var bitrateBps: Int
    var epoch: UInt32

    static let `default` = VideoProfile(width: Wire.defaultWidth, height: Wire.defaultHeight,
        fps: Wire.defaultFPS, gop: Wire.defaultGOP, bitrateBps: Wire.defaultBitrateBps,
        epoch: Wire.defaultEpoch)

    static func fromSelectProfile(width: Int, height: Int, fps: Int, gop: Int,
        bitrateBps: Int, epoch: UInt32) -> VideoProfile? {
        guard [30, 120, 240].contains(fps) else { return nil }
        guard width > 0, height > 0, gop > 0 else { return nil }
        return VideoProfile(width: width, height: height, fps: fps, gop: gop,
            bitrateBps: bitrateBps, epoch: epoch)
    }

    static func bitrateFor(width: Int, height: Int, fps: Int) -> Int {
        let pixels = Int64(width) * Int64(height)
        let base: Int
        if pixels >= 3840 * 2160 {
            base = 16_000_000
        } else if pixels >= 1920 * 1080 {
            base = 4_000_000
        } else {
            base = 2_000_000
        }
        return fps >= 120 ? base * 4 : base
    }
}
