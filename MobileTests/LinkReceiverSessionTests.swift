import CoreMedia
import XCTest
@testable import StageGlassLinkCore

@MainActor
final class LinkReceiverSessionTests: XCTestCase {
    func testConnectProjectsTracksSubscribesCameraAndMatchingMicrophone() async throws {
        let camera = track("camera", participant: "a", name: "Camera A", kind: .camera)
        let microphone = track("microphone", participant: "a", name: "Camera A", kind: .microphone)
        let other = track("other", participant: "b", name: "Camera B", kind: .camera)
        let mediaSession = StubMediaSession(tracks: [other, microphone, camera])
        let receiver = LinkReceiverSession(session: mediaSession)

        try await receiver.connect(configuration: configuration)
        try await settle()

        XCTAssertEqual(receiver.state, .connected)
        XCTAssertEqual(receiver.selectedVideoTrack, camera.selectionID)
        XCTAssertEqual(receiver.selectedAudioTrack, microphone.selectionID)
        XCTAssertEqual(Set(mediaSession.subscribed), Set([camera.id, microphone.id]))
    }

    func testExplicitVideoChoiceMovesAudioToSameParticipantAndRoutesOnlySelection() async throws {
        let cameraA = track("camera-a", participant: "a", name: "A", kind: .camera)
        let microphoneA = track("microphone-a", participant: "a", name: "A", kind: .microphone)
        let cameraB = track("camera-b", participant: "b", name: "B", kind: .camera)
        let microphoneB = track("microphone-b", participant: "b", name: "B", kind: .microphone)
        let mediaSession = StubMediaSession(tracks: [cameraA, microphoneA, cameraB, microphoneB])
        let receiver = LinkReceiverSession(session: mediaSession)
        var videoIDs: [MediaTrackID] = []
        var audioIDs: [MediaTrackID] = []
        receiver.onVideoFrame = { id, _ in videoIDs.append(id) }
        receiver.onAudioFrame = { id, _ in audioIDs.append(id) }

        try await receiver.connect(configuration: configuration)
        try await settle()
        receiver.selectVideoTrack(cameraB.selectionID)
        try await settle()

        XCTAssertEqual(receiver.selectedAudioTrack, microphoneB.selectionID)
        let sample = try makeVideoSampleBuffer()
        mediaSession.onRemoteVideoFrame?(cameraA.id, sample)
        mediaSession.onRemoteVideoFrame?(cameraB.id, sample)
        mediaSession.onRemoteAudio?(microphoneA.id, sample)
        mediaSession.onRemoteAudio?(microphoneB.id, sample)
        try await settle()
        XCTAssertEqual(videoIDs, [cameraB.id])
        XCTAssertEqual(audioIDs, [microphoneB.id])
    }

    func testDisconnectClearsProjectionAndDoesNotOwnCapture() async throws {
        let mediaSession = StubMediaSession(tracks: [])
        let receiver = LinkReceiverSession(session: mediaSession)
        try await receiver.connect(configuration: configuration)
        await receiver.disconnect()
        XCTAssertEqual(receiver.state, .idle)
        XCTAssertEqual(receiver.remoteTracks, [])
        XCTAssertTrue(mediaSession.didDisconnect)
        XCTAssertNil(mediaSession.publishedSource, "Receiver foundation must never open or publish a camera")
        XCTAssertEqual(mediaSession.microphoneValues, [], "Receiver foundation must never open a microphone")
    }

    private var configuration: SessionConfiguration {
        SessionConfiguration(serverURL: URL(string: "wss://example.invalid"), roomName: "room", displayName: "iPad", accessToken: "runtime-token")
    }

    private func track(_ id: String, participant: String, name: String, kind: MediaTrackKind) -> RemoteMediaTrack {
        RemoteMediaTrack(id: .init(rawValue: id), participantID: .init(rawValue: participant), participantName: name, kind: kind, isMuted: false)
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 30_000_000) }

    private func makeVideoSampleBuffer() throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sampleBuffer), noErr)
        return try XCTUnwrap(sampleBuffer)
    }
}

private final class StubMediaSession: MediaSession {
    var state: SessionState = .idle
    var remoteTracks: [RemoteMediaTrack]
    var onStateChanged: ((SessionState) -> Void)?
    var onRemoteTracksChanged: (([RemoteMediaTrack]) -> Void)?
    var onRemoteVideoFrame: ((MediaTrackID, CMSampleBuffer) -> Void)?
    var onRemoteAudio: ((MediaTrackID, CMSampleBuffer) -> Void)?
    var subscribed: [MediaTrackID] = []
    var didDisconnect = false
    var publishedSource: LocalMediaSource?
    var microphoneValues: [Bool] = []

    init(tracks: [RemoteMediaTrack]) { remoteTracks = tracks }
    func connect(configuration: SessionConfiguration) async throws {
        state = .connected
        onStateChanged?(.connected)
        onRemoteTracksChanged?(remoteTracks)
    }
    func publishCamera(_ source: LocalMediaSource) async throws { publishedSource = source }
    func setMicrophoneEnabled(_ enabled: Bool) async throws { microphoneValues.append(enabled) }
    func subscribe(to trackID: MediaTrackID) async throws { subscribed.append(trackID) }
    func disconnect() async { didDisconnect = true; state = .idle }
    func currentStats() -> TransportStats? { nil }
}
