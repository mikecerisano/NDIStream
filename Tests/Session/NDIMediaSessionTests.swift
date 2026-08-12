import CoreMedia
import CoreVideo
import XCTest
@testable import NDIStream

final class NDIMediaSessionTests: XCTestCase {
    func testPublisherForwardsCameraAndEnabledMicrophoneAndStopsOnDisconnect() async throws {
        let sender = SenderSpy()
        let session = NDIMediaSession(
            endpoint: .publish(sourceName: "Camera A", clockVideo: true),
            makeSender: { _, _ in sender },
            makeReceiver: { _, _ in nil }
        )
        let source = LocalMediaSource()

        try await session.connect(configuration: .ndi(displayName: "Camera A"))
        try await session.publishCamera(source)
        try await session.setMicrophoneEnabled(true)
        source.emitVideo(try makePixelBuffer(), presentationTime: .zero)
        source.emitAudio(try makeAudioSampleBuffer())

        XCTAssertTrue(sender.waitForVideo(timeout: 2))
        XCTAssertTrue(sender.waitForAudio(timeout: 2))
        await session.disconnect()
        XCTAssertEqual(sender.stopCount, 1)
        XCTAssertEqual(session.state, .idle)
    }

    func testReceiverPublishesStableSyntheticTrackAndForwardsFrames() async throws {
        let receiver = ReceiverSpy()
        let session = NDIMediaSession(
            endpoint: .receive(sourceName: "Studio Feed", sourceAddress: "ndi://studio"),
            makeSender: { _, _ in nil },
            makeReceiver: { _, _ in receiver }
        )
        let tracksChanged = expectation(description: "tracks changed")
        let video = expectation(description: "video")
        let audio = expectation(description: "audio")
        let stateChanged = expectation(description: "reconnecting then connected")
        stateChanged.expectedFulfillmentCount = 2
        session.onRemoteTracksChanged = { tracks in
            XCTAssertEqual(tracks.count, 1)
            XCTAssertEqual(tracks.first?.participantName, "Studio Feed")
            tracksChanged.fulfill()
        }
        session.onRemoteVideoFrame = { trackID, _ in
            XCTAssertEqual(trackID, session.remoteTracks.first?.id)
            video.fulfill()
        }
        session.onRemoteAudio = { trackID, sampleBuffer in
            XCTAssertEqual(trackID, session.remoteTracks.first?.id)
            XCTAssertEqual(CMSampleBufferGetNumSamples(sampleBuffer), 2)
            audio.fulfill()
        }

        try await session.connect(configuration: .ndi(displayName: "Receiver"))
        let track = try XCTUnwrap(session.remoteTracks.first)
        try await session.subscribe(to: track.id)
        await fulfillment(of: [tracksChanged], timeout: 2)
        receiver.emitVideo(try makeVideoSampleBuffer())
        receiver.emitAudio()
        await fulfillment(of: [video, audio], timeout: 2)

        session.onStateChanged = { state in
            if state == .reconnecting || state == .connected { stateChanged.fulfill() }
        }
        receiver.emitStall()
        receiver.emitResume()
        await fulfillment(of: [stateChanged], timeout: 2)
        await session.disconnect()
        XCTAssertEqual(receiver.stopCount, 1)
    }

    func testSubscribeRejectsUnknownTrackWithoutCreatingReceiver() async throws {
        var receiverCreations = 0
        let session = NDIMediaSession(
            endpoint: .receive(sourceName: "Studio", sourceAddress: "ndi://studio"),
            makeSender: { _, _ in nil },
            makeReceiver: { _, _ in receiverCreations += 1; return ReceiverSpy() }
        )
        try await session.connect(configuration: .ndi(displayName: "Receiver"))

        do {
            try await session.subscribe(to: MediaTrackID(rawValue: "unknown"))
            XCTFail("Expected unknown track to fail")
        } catch let error as NDIMediaSession.Error {
            XCTAssertEqual(error, .unknownTrack)
        }
        XCTAssertEqual(receiverCreations, 0)
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func makeVideoSampleBuffer() throws -> CMSampleBuffer {
        let pixelBuffer = try makePixelBuffer()
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &description
        ), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: try XCTUnwrap(description),
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ), noErr)
        return try XCTUnwrap(sample)
    }

    private func makeAudioSampleBuffer() throws -> CMSampleBuffer {
        try XCTUnwrap(AudioSampleBufferFactory.makeInterleavedFloat(
            samples: [0], sampleRate: 48_000, channels: 1, presentationTime: .zero
        ))
    }
}

private final class SenderSpy: VideoSender {
    private let lock = NSLock()
    private let videoSemaphore = DispatchSemaphore(value: 0)
    private let audioSemaphore = DispatchSemaphore(value: 0)
    private(set) var stopCount = 0

    func send(pixelBuffer: CVPixelBuffer, frameRateN: Int32, frameRateD: Int32) { videoSemaphore.signal() }
    func repeatLastFrame(frameRateN: Int32, frameRateD: Int32) {}
    func sendAudio(_ sampleBuffer: CMSampleBuffer) { audioSemaphore.signal() }
    func stop() { lock.lock(); stopCount += 1; lock.unlock() }
    func waitForVideo(timeout: TimeInterval) -> Bool { videoSemaphore.wait(timeout: .now() + timeout) == .success }
    func waitForAudio(timeout: TimeInterval) -> Bool { audioSemaphore.wait(timeout: .now() + timeout) == .success }
}

private final class ReceiverSpy: VideoReceiver {
    weak var delegate: VideoReceiverDelegate?
    private(set) var stopCount = 0
    func stop() { stopCount += 1 }
    func emitVideo(_ sample: CMSampleBuffer) {
        delegate?.videoReceiverDidReceive(sampleBuffer: sample, width: 2, height: 2,
                                          frameRateN: 30, frameRateD: 1, fourCC: 0)
    }
    func emitStall() { delegate?.videoReceiverDidStall(forSeconds: 2) }
    func emitResume() { delegate?.videoReceiverDidResume() }
    func emitAudio() {
        let samples: [Float] = [0.1, 0.2]
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            delegate?.videoReceiverDidReceiveAudio(
                samples: baseAddress,
                sampleRate: 48_000,
                channels: 1,
                samplesPerChannel: 2,
                channelStrideBytes: Int32(2 * MemoryLayout<Float>.stride)
            )
        }
    }
}
