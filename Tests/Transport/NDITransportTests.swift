import XCTest
@testable import NDIStream

final class NDITransportTests: XCTestCase {

    // MARK: Release capabilities

    func testReleaseCapabilitiesContainExactlyLinkAndNDI() {
        XCTAssertEqual(LinkMode.releaseCapabilities, [.link, .ndi])
        XCTAssertEqual(LinkMode.allCases, [.link, .ndi])
        XCTAssertEqual(LinkMode.releaseCapabilities.map(\.displayName), ["Link", "NDI"])
    }

    // MARK: FoundSource

    func testFoundSourceCarriesRoomCode() {
        let s = FoundSource(name: "X", address: "1.2.3.4", transport: .warpStream,
                            port: 7000, pinSHA256: Data([1,2,3]), roomCode: "ABC123")
        XCTAssertEqual(s.roomCode, "ABC123")
    }

    func testFoundSourceRoomCodeDefaultsNil() {
        let s = FoundSource(name: "X", address: "1.2.3.4", transport: .ndi)
        XCTAssertNil(s.roomCode)
    }

    func testFoundSourceMappingTagsNDI() {
        let mapped = NDISourceFinder.mapForTesting(name: "CAM (Mac Camera)", address: "10.0.0.5")
        XCTAssertEqual(mapped, FoundSource(name: "CAM (Mac Camera)", address: "10.0.0.5", transport: .ndi))
    }

    // MARK: TransportStats

    func testTransportStatsRoundtrip() {
        let s = TransportStats(bitrateKbps: 8400, sendLatencyMs: 12, wireLatencyMs: 18,
                               receiveLatencyMs: 32, endToEndLatencyMs: 62,
                               jitterBufferMs: 24, framesDropped: 3, cpuPercent: 14.5)
        XCTAssertEqual(s.bitrateKbps, 8400)
        XCTAssertEqual(s.sendLatencyMs, 12)
        XCTAssertEqual(s.wireLatencyMs, 18)
        XCTAssertEqual(s.receiveLatencyMs, 32)
        XCTAssertEqual(s.endToEndLatencyMs, 62)
        XCTAssertEqual(s.jitterBufferMs, 24)
        XCTAssertEqual(s.framesDropped, 3)
        XCTAssertEqual(s.cpuPercent, 14.5)
    }

    func testTransportStatsAllowsNilLatencies() {
        let s = TransportStats(bitrateKbps: 100, framesDropped: 0, cpuPercent: 5)
        XCTAssertNil(s.sendLatencyMs)
        XCTAssertNil(s.wireLatencyMs)
        XCTAssertNil(s.receiveLatencyMs)
        XCTAssertNil(s.endToEndLatencyMs)
        XCTAssertNil(s.jitterBufferMs)
    }

    // MARK: NDI adapter stats placeholder

    func testNDIVideoSenderCurrentStatsReturnsNilForNow() {
        // The NDI SDK doesn't expose stats; the adapter returns nil until we have a meter.
        // This test pins behavior so we notice when we wire something in.
        let sender = NDIVideoSender(sourceName: "TestSrc", clockVideo: false)
        // Sender may be nil if NDI runtime isn't initialized in the test host; only check stats if alive.
        if let sender = sender {
            XCTAssertNil(sender.currentStats(),
                         "NDI adapter has no stats meter yet; expect nil until one is added")
            sender.stop()
        }
    }

    // MARK: Factory routing

    func testFactoryReturnsNilForLinkUntilLiveKitAdapterLands() {
        let sender = TransportFactory.makeSender(mode: .link,
                                                 sourceName: "X", clockVideo: false)
        XCTAssertNil(sender)
    }

    func testFactoryRejectsExperimentalReceiverSource() {
        let src = FoundSource(name: "X", address: "1.2.3.4", transport: .quicLink)
        XCTAssertNil(TransportFactory.makeReceiver(for: src))
    }

    func testReleaseFactoryCreatesOnlyNDIFinder() {
        let finders = TransportFactory.makeFinders()
        XCTAssertEqual(finders.count, 1)
        XCTAssertTrue(finders[0] is NDISourceFinder)
    }

    func testWarpStreamFinderMappingSeam() {
        let fp = Data([0xab, 0xcd])
        let s = WarpStreamSourceFinder.mapForTesting(name: "Mike's Camera",
                                                     host: "10.0.0.7",
                                                     port: 7000,
                                                     pskFingerprint: fp,
                                                     roomCode: "ABC123")
        XCTAssertEqual(s.name, "Mike's Camera")
        XCTAssertEqual(s.address, "10.0.0.7")
        XCTAssertEqual(s.transport, .warpStream)
        XCTAssertEqual(s.port, 7000)
        XCTAssertEqual(s.pinSHA256, fp)
        XCTAssertEqual(s.roomCode, "ABC123")
    }
}
