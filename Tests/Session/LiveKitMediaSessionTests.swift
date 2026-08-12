import CoreMedia
import CoreVideo
import XCTest
@testable import NDIStream

final class LiveKitMediaSessionTests: XCTestCase {
    func testConnectMapsStateTracksAndNeverRetainsTokenInFailure() async throws {
        let client = LiveKitClientSpy()
        let session = LiveKitMediaSession(client: client)
        let token = "one-time-secret"

        try await session.connect(configuration: SessionConfiguration(
            serverURL: try XCTUnwrap(URL(string: "wss://link.example.test")),
            roomName: "camera-a",
            displayName: "Camera A",
            accessToken: token
        ))
        XCTAssertEqual(client.connectedURL?.absoluteString, "wss://link.example.test")
        XCTAssertEqual(client.connectedToken, token)

        client.emitState(.connected)
        XCTAssertEqual(session.state, .connected)

        client.emitTracks([.init(
            id: "track-camera",
            participantID: "participant-a",
            participantName: "Camera A",
            kind: .camera,
            isMuted: false
        )])
        XCTAssertEqual(session.remoteTracks, [RemoteMediaTrack(
            id: MediaTrackID(rawValue: "track-camera"),
            participantID: ParticipantID(rawValue: "participant-a"),
            participantName: "Camera A",
            kind: .camera,
            isMuted: false
        )])

        client.emitState(.failed("join failed token=\(token)"))
        guard case let .failed(message) = session.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertFalse(message.contains(token))
        XCTAssertTrue(message.contains("<redacted>"))
    }

    func testPublishCameraUsesApplicationOwnedFramesAndDoesNotForwardSourceAudio() async throws {
        let client = LiveKitClientSpy()
        let session = LiveKitMediaSession(client: client)
        let source = LocalMediaSource()

        try await connect(session)
        try await session.publishCamera(source)
        source.emitVideo(try makePixelBuffer(), presentationTime: CMTime(value: 2, timescale: 30))
        source.emitAudio(try makeAudioSampleBuffer())

        await fulfillment(of: [client.firstFramePublished], timeout: 2)
        XCTAssertEqual(client.publishedFrameTimes, [CMTime(value: 2, timescale: 30)])
        XCTAssertEqual(session.audioCaptureOwnership, .liveKitSDK)
        XCTAssertEqual(client.customAudioFrames, 0)

        try await session.setMicrophoneEnabled(true)
        XCTAssertEqual(client.microphoneValues, [true])
    }

    func testSubscribesAndConvertsRemoteVideoToSampleBuffer() async throws {
        let client = LiveKitClientSpy()
        let session = LiveKitMediaSession(client: client)
        let received = expectation(description: "remote video")
        session.onRemoteVideoFrame = { trackID, sampleBuffer in
            XCTAssertEqual(trackID, MediaTrackID(rawValue: "remote-camera"))
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), CMTime(value: 7, timescale: 30))
            received.fulfill()
        }

        try await connect(session)
        client.emitTracks([.init(
            id: "remote-camera",
            participantID: "remote",
            participantName: "Remote",
            kind: .camera,
            isMuted: false
        )])
        try await session.subscribe(to: MediaTrackID(rawValue: "remote-camera"))
        XCTAssertEqual(client.subscribedTrackIDs, ["remote-camera"])
        client.emitVideo(trackID: "remote-camera", pixelBuffer: try makePixelBuffer(), pts: CMTime(value: 7, timescale: 30))
        await fulfillment(of: [received], timeout: 2)
    }

    func testDisconnectCancelsSourceAndIgnoresLateClientEvents() async throws {
        let client = LiveKitClientSpy()
        let session = LiveKitMediaSession(client: client)
        let source = LocalMediaSource()
        try await connect(session)
        try await session.publishCamera(source)

        await session.disconnect()
        XCTAssertEqual(client.disconnectCount, 1)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.remoteTracks, [])

        source.emitVideo(try makePixelBuffer(), presentationTime: .zero)
        client.emitState(.connected)
        client.emitTracks([.init(id: "late", participantID: "late", participantName: "Late", kind: .camera, isMuted: false)])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.publishedFrameTimes, [])
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.remoteTracks, [])
    }

    private func connect(_ session: LiveKitMediaSession) async throws {
        try await session.connect(configuration: SessionConfiguration(
            serverURL: try XCTUnwrap(URL(string: "wss://link.example.test")),
            roomName: "room",
            displayName: "Camera",
            accessToken: "token"
        ))
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func makeAudioSampleBuffer() throws -> CMSampleBuffer {
        try XCTUnwrap(AudioSampleBufferFactory.makeInterleavedFloat(
            samples: [0], sampleRate: 48_000, channels: 1, presentationTime: .zero
        ))
    }
}

private final class LiveKitClientSpy: LiveKitClient {
    var onStateChanged: ((LiveKitClientState) -> Void)?
    var onTracksChanged: (([LiveKitTrackDescriptor]) -> Void)?
    var onVideoFrame: ((_ trackID: String, _ pixelBuffer: CVPixelBuffer, _ presentationTime: CMTime) -> Void)?

    let firstFramePublished = XCTestExpectation(description: "first frame published")
    var connectedURL: URL?
    var connectedToken: String?
    var publishedFrameTimes: [CMTime] = []
    var microphoneValues: [Bool] = []
    var subscribedTrackIDs: [String] = []
    var disconnectCount = 0
    var customAudioFrames = 0

    func connect(serverURL: URL, token: String) async throws {
        connectedURL = serverURL
        connectedToken = token
    }

    func publishCamera(firstFrame: CVPixelBuffer, presentationTime: CMTime) async throws {
        publishedFrameTimes.append(presentationTime)
        firstFramePublished.fulfill()
    }

    func capture(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        publishedFrameTimes.append(presentationTime)
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws { microphoneValues.append(enabled) }
    func subscribe(to trackID: String) async throws { subscribedTrackIDs.append(trackID) }
    func disconnect() async { disconnectCount += 1 }

    func emitState(_ state: LiveKitClientState) { onStateChanged?(state) }
    func emitTracks(_ tracks: [LiveKitTrackDescriptor]) { onTracksChanged?(tracks) }
    func emitVideo(trackID: String, pixelBuffer: CVPixelBuffer, pts: CMTime) {
        onVideoFrame?(trackID, pixelBuffer, pts)
    }
}
