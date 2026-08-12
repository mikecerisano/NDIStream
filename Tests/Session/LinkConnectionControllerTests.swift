import XCTest
import CoreMedia
import CoreVideo
@testable import NDIStream

@MainActor
final class LinkConnectionControllerTests: XCTestCase {
    func testTokenIsRuntimeOnlyAndClearedOnLeave() async {
        let suite = "LinkConnectionControllerTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = StubMediaSession()
        let controller = LinkConnectionController(defaults: defaults,
                                                  keyPrefix: "sender",
                                                  defaultDisplayName: "Camera",
                                                  makeSession: { session })
        controller.serverURL = "wss://example.invalid"
        controller.roomName = "stage-a"
        controller.displayName = "Camera A"
        controller.accessToken = "secret-token"
        controller.saveNonSecretFields(to: defaults, keyPrefix: "sender")

        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains("secret-token") })
        await controller.join()
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(session.receivedConfiguration?.accessToken, "secret-token")
        await controller.leave()
        XCTAssertEqual(controller.accessToken, "")
        XCTAssertEqual(controller.state, .idle)
    }

    func testUnavailableSessionFailsTruthfully() async {
        let controller = LinkConnectionController(keyPrefix: "test",
                                                  defaultDisplayName: "Camera",
                                                  makeSession: nil)
        controller.serverURL = "wss://example.invalid"
        controller.roomName = "room"
        controller.displayName = "Camera"
        controller.accessToken = "token"
        await controller.join()
        XCTAssertFalse(controller.isJoined)
        XCTAssertEqual(controller.state, .failed(message: "Link is not available in this build."))
    }

    func testRejectsInsecureOrIncompleteInputWithoutCreatingSession() async {
        var factoryCalls = 0
        let controller = LinkConnectionController(keyPrefix: "test",
                                                  defaultDisplayName: "Camera",
                                                  makeSession: { factoryCalls += 1; return StubMediaSession() })
        controller.serverURL = "http://example.invalid"
        controller.roomName = "room"
        controller.displayName = "Camera"
        controller.accessToken = "token"
        await controller.join()
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(controller.state, .failed(message: "Enter a valid secure Link server URL."))
    }

    func testJoinedControllerPublishesCameraAndAppliesMicrophonePolicy() async throws {
        let session = StubMediaSession()
        let controller = joinedController(session: session)
        await controller.join()
        let source = LocalMediaSource()

        try await controller.publishCamera(source)
        try await controller.setMicrophoneEnabled(true)

        XCTAssertTrue(session.publishedSource === source)
        XCTAssertEqual(session.microphoneValues, [true])
    }

    func testPublishingBeforeJoinFailsTruthfully() async {
        let controller = LinkConnectionController(keyPrefix: "test",
                                                  defaultDisplayName: "Camera",
                                                  makeSession: { StubMediaSession() })
        do {
            try await controller.publishCamera(LocalMediaSource())
            XCTFail("Expected publish to require a joined Link session")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Join a Link session before starting the camera.")
        }
    }

    func testMicrophoneChangeBeforeJoinFailsTruthfully() async {
        let controller = LinkConnectionController(keyPrefix: "test",
                                                  defaultDisplayName: "Camera",
                                                  makeSession: { StubMediaSession() })
        do {
            try await controller.setMicrophoneEnabled(true)
            XCTFail("Expected microphone policy to require a joined Link session")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Join a Link session before changing the microphone.")
        }
    }

    func testJoinCanRecoverAfterConnectedSessionLaterFails() async {
        let failedSession = StubMediaSession()
        let replacement = StubMediaSession()
        var sessions = [failedSession, replacement]
        let controller = LinkConnectionController(keyPrefix: "test",
                                                  defaultDisplayName: "Camera",
                                                  makeSession: { sessions.removeFirst() })
        controller.serverURL = "wss://example.invalid"
        controller.roomName = "room"
        controller.displayName = "Camera"
        controller.accessToken = "token"

        await controller.join()
        failedSession.fail(message: "network lost")
        await Task.yield()
        XCTAssertEqual(controller.state, .failed(message: "network lost"))

        await controller.join()

        XCTAssertEqual(controller.state, .connected)
        XCTAssertTrue(failedSession.didDisconnect)
        XCTAssertNotNil(replacement.receivedConfiguration)
    }

    private func joinedController(session: StubMediaSession) -> LinkConnectionController {
        let controller = LinkConnectionController(keyPrefix: "test",
                                                  defaultDisplayName: "Camera",
                                                  makeSession: { session })
        controller.serverURL = "wss://example.invalid"
        controller.roomName = "room"
        controller.displayName = "Camera"
        controller.accessToken = "token"
        return controller
    }
    func testSelectsStableCameraAndMatchingMicrophoneAndSubscribesBoth() async throws {
        let session = StubMediaSession()
        let controller = configuredController(session: session)
        await controller.join()

        let cameraA = track("camera-a", participant: "a", name: "Camera A", kind: .camera)
        let microphoneA = track("microphone-a", participant: "a", name: "Camera A", kind: .microphone)
        let cameraB = track("camera-b", participant: "b", name: "Camera B", kind: .camera)
        session.emitTracks([cameraB, microphoneA, cameraA])
        try await settleCallbacks()

        XCTAssertEqual(controller.selectedVideoTrack, cameraA.selectionID)
        XCTAssertEqual(controller.selectedAudioTrack, microphoneA.selectionID)
        XCTAssertEqual(Set(session.subscribedTrackIDs), Set([cameraA.id, microphoneA.id]))

        session.emitTracks([cameraB, cameraA, microphoneA])
        try await settleCallbacks()
        XCTAssertEqual(controller.selectedVideoTrack, cameraA.selectionID)
        XCTAssertEqual(controller.selectedAudioTrack, microphoneA.selectionID)
        XCTAssertEqual(session.subscribedTrackIDs.count, 2, "Track list reordering must not resubscribe or change selection")
    }

    func testReplacesDepartedTrackButDoesNotSwitchAwayFromMutedSelectedParticipant() async throws {
        let session = StubMediaSession()
        let controller = configuredController(session: session)
        await controller.join()
        let cameraA = track("camera-a", participant: "a", name: "Camera A", kind: .camera)
        let cameraAMuted = RemoteMediaTrack(id: cameraA.id, participantID: cameraA.participantID,
                                            participantName: cameraA.participantName, kind: .camera, isMuted: true)
        let cameraB = track("camera-b", participant: "b", name: "Camera B", kind: .camera)

        session.emitTracks([cameraA, cameraB])
        try await settleCallbacks()
        session.emitTracks([cameraAMuted, cameraB])
        try await settleCallbacks()
        XCTAssertEqual(controller.selectedVideoTrack, cameraA.selectionID,
                       "A temporary mute must not jump the monitor to another participant")

        session.emitTracks([cameraB])
        try await settleCallbacks()
        XCTAssertEqual(controller.selectedVideoTrack, cameraB.selectionID)
    }

    func testRoutesOnlySelectedTrackFramesAndClearsMediaOnLeave() async throws {
        let session = StubMediaSession()
        let controller = configuredController(session: session)
        let cameraA = track("camera-a", participant: "a", name: "Camera A", kind: .camera)
        let cameraB = track("camera-b", participant: "b", name: "Camera B", kind: .camera)
        var receivedVideo: [MediaTrackID] = []
        controller.onRemoteVideoFrame = { id, _ in receivedVideo.append(id) }
        await controller.join()
        session.emitTracks([cameraA, cameraB])
        try await settleCallbacks()

        let sample = try makeVideoSampleBuffer()
        session.onRemoteVideoFrame?(cameraB.id, sample)
        session.onRemoteVideoFrame?(cameraA.id, sample)
        try await settleCallbacks()
        XCTAssertEqual(receivedVideo, [cameraA.id])

        await controller.leave()
        XCTAssertEqual(controller.remoteTracks, [])
        XCTAssertNil(controller.selectedVideoTrack)
        XCTAssertNil(controller.selectedAudioTrack)
    }

    private func configuredController(session: StubMediaSession) -> LinkConnectionController {
        let controller = LinkConnectionController(keyPrefix: "test-\(UUID())",
                                                  defaultDisplayName: "Receiver",
                                                  makeSession: { session })
        controller.serverURL = "wss://example.invalid"
        controller.roomName = "room"
        controller.displayName = "Receiver"
        controller.accessToken = "token"
        return controller
    }

    private func track(_ id: String, participant: String, name: String,
                       kind: MediaTrackKind) -> RemoteMediaTrack {
        RemoteMediaTrack(id: MediaTrackID(rawValue: id), participantID: ParticipantID(rawValue: participant),
                         participantName: name, kind: kind, isMuted: false)
    }

    private func makeVideoSampleBuffer() throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 2,
                                           kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                     imageBuffer: imageBuffer,
                                                                     formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(value: 2, timescale: 30),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                                 imageBuffer: imageBuffer,
                                                                 formatDescription: try XCTUnwrap(description),
                                                                 sampleTiming: &timing,
                                                                 sampleBufferOut: &sampleBuffer), noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    private func settleCallbacks() async throws {
        try await Task.sleep(nanoseconds: 30_000_000)
    }
}

private final class StubMediaSession: MediaSession {
    var state: SessionState = .idle
    var remoteTracks: [RemoteMediaTrack] = []
    var onStateChanged: ((SessionState) -> Void)?
    var onRemoteTracksChanged: (([RemoteMediaTrack]) -> Void)?
    var onRemoteVideoFrame: ((MediaTrackID, CMSampleBuffer) -> Void)?
    var onRemoteAudio: ((MediaTrackID, CMSampleBuffer) -> Void)?
    var receivedConfiguration: SessionConfiguration?
    var publishedSource: LocalMediaSource?
    var microphoneValues: [Bool] = []
    var didDisconnect = false
    var subscribedTrackIDs: [MediaTrackID] = []

    func connect(configuration: SessionConfiguration) async throws {
        receivedConfiguration = configuration
        state = .connected
        onStateChanged?(.connected)
    }
    func publishCamera(_ source: LocalMediaSource) async throws { publishedSource = source }
    func setMicrophoneEnabled(_ enabled: Bool) async throws { microphoneValues.append(enabled) }
    func subscribe(to trackID: MediaTrackID) async throws { subscribedTrackIDs.append(trackID) }
    func disconnect() async { didDisconnect = true; state = .idle }
    func currentStats() -> TransportStats? { nil }

    func fail(message: String) {
        state = .failed(message: message)
        onStateChanged?(state)
    }

    func emitTracks(_ tracks: [RemoteMediaTrack]) {
        remoteTracks = tracks
        onRemoteTracksChanged?(tracks)
    }
}
