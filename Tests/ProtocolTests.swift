import XCTest
@testable import CardAICollector

final class ProtocolTests: XCTestCase {
    func testGroupHeaderRoundTrip() throws {
        let config = Data([0, 0, 0, 1, 0x40, 0x01, 0x0c, 0x01])
        let packed = try Wire.packGroupHeader(
            flags: Wire.flagKeyframe | Wire.flagEpochStart,
            epoch: 7, groupSeq: 42, frameCount: 15, config: config)
        XCTAssertEqual(packed.count, Wire.groupHeaderFixed + config.count)
        let parsed = try Wire.unpackGroupHeader(packed)
        XCTAssertTrue(parsed.keyframe)
        XCTAssertTrue(parsed.epochStart)
        XCTAssertEqual(parsed.epoch, 7)
        XCTAssertEqual(parsed.groupSeq, 42)
        XCTAssertEqual(parsed.frameCount, 15)
        XCTAssertEqual(parsed.config, config)
        XCTAssertEqual(parsed.headerLen, packed.count)
    }

    func testGroupHeaderRejectsBadMagicVersionAndTruncation() throws {
        let good = try Wire.packGroupHeader(flags: 0, epoch: 0, groupSeq: 0, frameCount: 1)
        var badMagic = good
        badMagic.replaceSubrange(0..<4, with: [0x58, 0x58, 0x58, 0x58])
        XCTAssertThrowsError(try Wire.unpackGroupHeader(badMagic))
        var badVersion = good
        badVersion[4] = 2
        XCTAssertThrowsError(try Wire.unpackGroupHeader(badVersion))
        XCTAssertThrowsError(try Wire.unpackGroupHeader(good.subdata(in: 0..<10)))
        var declared = good
        declared[16] = 0
        declared[17] = 9
        XCTAssertThrowsError(try Wire.unpackGroupHeader(declared))
    }

    func testControlFrameRoundTripAndBounds() throws {
        let message: [String: Any] = ["type": "hello", "device_id": "ios-1", "note": "中文载荷"]
        let frame = try Wire.packControl(message)
        XCTAssertEqual(Int(UInt32(bigEndian: frame.withUnsafeBytes { $0.load(as: UInt32.self) })),
            frame.count - 4)
        let parsed = try Wire.unpackControl(frame)
        XCTAssertEqual(parsed["device_id"] as? String, "ios-1")
        XCTAssertThrowsError(try Wire.packControl(
            ["type": "hello", "blob": String(repeating: "x", count: Wire.maxControlFrame)]))
        var mismatch = Data([0, 0, 0, 10])
        mismatch.append(contentsOf: [0x7b, 0x7d])
        XCTAssertThrowsError(try Wire.unpackControl(mismatch))
    }

    func testFrameHeaderRoundTrip() throws {
        let header = Wire.packFrameHeader(frameLen: 4096, frameId: 123456,
            captureUtcUs: 1_753_000_000_000_000)
        XCTAssertEqual(header.count, 16)
        let parsed = try Wire.unpackFrameHeader(header)
        XCTAssertEqual(parsed.frameLen, 4096)
        XCTAssertEqual(parsed.frameId, 123456)
        XCTAssertEqual(parsed.captureUtcUs, 1_753_000_000_000_000)
    }

    func testAnnexBSplitAndParameterSetOrder() throws {
        let vps = Data([0x40, 0x01, 0x0c, 0x01, 0xFF])
        let sps = Data([0x42, 0x01, 0x01, 0x01, 0x20])
        let pps = Data([0x44, 0x01, 0xC0])
        var stream = Data([0, 0, 0, 1]); stream.append(vps)
        stream.append(contentsOf: [0, 0, 1]); stream.append(sps)
        stream.append(contentsOf: [0, 0, 0, 1]); stream.append(pps)
        let nals = Wire.splitAnnexB(stream)
        XCTAssertEqual(nals, [vps, sps, pps])
        XCTAssertEqual(nals.map { Wire.nalType($0) }, [32, 33, 34])
        var shuffled = Data([0, 0, 0, 1]); shuffled.append(pps)
        shuffled.append(contentsOf: [0, 0, 1]); shuffled.append(vps)
        shuffled.append(contentsOf: [0, 0, 1]); shuffled.append(sps)
        XCTAssertEqual(Wire.splitAnnexB(Wire.parameterSets(shuffled)), [vps, sps, pps])
    }

    func testIDRDetectionAndAVCCConversion() throws {
        var idr = Data([0, 0, 0, 1, 0x40, 0x01, 0x0c, 0x01])
        idr.append(contentsOf: [0, 0, 0, 1, 0x26, 0x01, 0xAF])
        var nonIdr = Data([0, 0, 0, 1, 0x02, 0x01, 0xD0, 0x09])
        XCTAssertTrue(Wire.isIDRAccessUnit(idr))
        XCTAssertFalse(Wire.isIDRAccessUnit(nonIdr))
        nonIdr = Data()
        let nal = Data([0x26, 0x01, 0xAF])
        var avcc = Data([0, 0, 0, 3])
        avcc.append(nal)
        XCTAssertEqual(Wire.annexB(fromAVCC: avcc), Data([0, 0, 0, 1]) + nal)
    }
}
