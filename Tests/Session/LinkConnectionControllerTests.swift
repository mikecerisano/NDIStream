import XCTest
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

    func connect(configuration: SessionConfiguration) async throws {
        receivedConfiguration = configuration
        state = .connected
        onStateChanged?(.connected)
    }
    func publishCamera(_ source: LocalMediaSource) async throws { publishedSource = source }
    func setMicrophoneEnabled(_ enabled: Bool) async throws { microphoneValues.append(enabled) }
    func subscribe(to trackID: MediaTrackID) async throws {}
    func disconnect() async { didDisconnect = true; state = .idle }
    func currentStats() -> TransportStats? { nil }

    func fail(message: String) {
        state = .failed(message: message)
        onStateChanged?(state)
    }
}
