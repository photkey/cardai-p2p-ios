import CoreMedia
import Foundation

/// NTP 式单程估计：取最小 RTT 样本的 `((t2-t1)+(t3-t4))/2` 作为 offset。
/// 锚点用 CoreMedia host clock，采样 PTS 与 host clock 同源。
final class ClockSync: @unchecked Sendable {
    private let lock = NSLock()
    private var _offsetUs: Int64 = 0
    private var bestRttUs: Int64 = .max
    private var anchorUtcUs: Int64 = 0
    private var anchorHostUs: Int64 = 0

    var offsetUs: Int64 { lock.withLock { _offsetUs } }
    var resolved: Bool { lock.withLock { bestRttUs != .max } }

    static func hostNowUs() -> Int64 {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        return CMTimeConvertScale(time, timescale: 1_000_000, method: .default).value
    }

    static func wallNowUs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000)
    }

    func onReply(seq: Int, t1Us: Int64, t2Us: Int64, t3Us: Int64) {
        guard t1Us > 0, t2Us > 0, t3Us > 0 else { return }
        let t4 = Self.wallNowUs()
        let rtt = (t4 - t1Us) - (t3Us - t2Us)
        let offset = ((t2Us - t1Us) + (t3Us - t4)) / 2
        lock.withLock {
            guard bestRttUs == .max || rtt < bestRttUs else { return }
            bestRttUs = rtt
            _offsetUs = offset
            anchorUtcUs = Self.wallNowUs() + offset
            anchorHostUs = Self.hostNowUs()
        }
    }

    func startAnchor() {
        lock.withLock {
            anchorUtcUs = Self.wallNowUs() + _offsetUs
            anchorHostUs = Self.hostNowUs()
        }
    }

    func utcFromHost(_ hostUs: Int64) -> Int64 {
        lock.withLock { anchorUtcUs + (hostUs - anchorHostUs) }
    }

    func utcFromWall() -> Int64 {
        Self.wallNowUs() + offsetUs
    }
}
