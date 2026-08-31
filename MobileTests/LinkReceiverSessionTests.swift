import AVFoundation
import CoreMedia
import XCTest
@testable import StageGlassLinkCore

@MainActor
final class LinkReceiverSessionTests: XCTestCase {
    func testDuplexSessionConnectsPublishesAndDisconnectsOneMediaSession() async throws {
        let mediaSession = StubMediaSession(tracks: [])
        let duplex = LinkDuplexSession(session: mediaSession)
        let source = LocalMediaSource()

        try await duplex.connect(configuration: configuration)
        try await duplex.publish(source, microphoneEnabled: true)
        await duplex.disconnect()

        XCTAssertTrue(mediaSession.publishedSource === source)
        XCTAssertEqual(mediaSession.microphoneValues, [true])
        XCTAssertTrue(mediaSession.didDisconnect)
    }

    func testPublisherForwardsApplicationOwnedVideoAndAudioWithoutCreatingCapture() async throws {
        let client = LinkLiveKitClientSpy()
        let session = LiveKitMediaSession(client: client)
        let source = LocalMediaSource()
        try await session.connect(configuration: configuration)

        try await session.publishCamera(source)
        source.emitVideo(try makePixelBuffer(), presentationTime: CMTime(value: 2, timescale: 30))
        source.emitAudio(try makeAudioSampleBuffer())
        try await settle()

        XCTAssertEqual(client.publishedFrameTimes, [CMTime(value: 2, timescale: 30)])
        XCTAssertEqual(client.capturedAudioCount, 1)
        XCTAssertEqual(session.audioCaptureOwnership, .application)
    }

    func testCameraOffBeforeFirstFrameIsReappliedAfterLazyTrackPublication() async throws {
        let client = LinkLiveKitClientSpy()
        let session = LiveKitMediaSession(client: client)
        let source = LocalMediaSource()
        try await session.connect(configuration: configuration)
        try await session.publishCamera(source)

        try await session.setCameraPublishEnabled(false)
        XCTAssertEqual(client.cameraPublishValues, [false])

        source.emitVideo(try makePixelBuffer(), presentationTime: .zero)
        try await settle()

        XCTAssertEqual(client.publishedFrameTimes, [.zero])
        XCTAssertEqual(client.cameraPublishValues, [false, false],
                       "camera-off must be reconciled after the first frame creates the SDK track")
    }

    func testFloat32InterleavedSampleConvertsToLiveKitPCMBuffer() throws {
        let sample = try XCTUnwrap(AudioSampleBufferFactory.makeInterleavedFloat(
            samples: [0.25, -0.5], sampleRate: 48_000, channels: 1, presentationTime: .zero
        ))
        let converted = try XCTUnwrap(LiveKitSDKClient.makePCMBuffer(from: sample))

        XCTAssertEqual(converted.frameLength, 2)
        XCTAssertEqual(converted.audioBufferList.pointee.mBuffers.mDataByteSize, 8)
        let data = try XCTUnwrap(converted.audioBufferList.pointee.mBuffers.mData)
            .assumingMemoryBound(to: Float.self)
        XCTAssertEqual(data[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(data[1], -0.5, accuracy: 0.0001)
    }

    func testConnectProjectsTracksSubscribesCameraAndMatchingMicrophone() async throws {
        let camera = track("camera", participant: "a", name: "Camera A", kind: .camera)
        let microphone = track("microphone", participant: "a", name: "Camera A", kind: .microphone)
        let other = track("other", participant: "b", name: "Camera B", kind: .camera)
        let mediaSession = StubMediaSession(tracks: [other, microphone, camera])
        let receiver = LinkReceiverSession(session: mediaSession)
        receiver.isAudioSubscriptionEnabled = true

        try await receiver.connect(configuration: configuration)
        try await settle()

        XCTAssertEqual(receiver.state, .connected)
        XCTAssertEqual(receiver.selectedVideoTrack, camera.selectionID)
        XCTAssertEqual(receiver.selectedAudioTrack, microphone.selectionID)
        XCTAssertEqual(Set(mediaSession.subscribed), Set([camera.id, microphone.id]))
    }

    func testAudioOnlyPublisherIsSelectedAndSubscribed() async throws {
        let microphone = track("microphone", participant: "audio-only", name: "Audio A", kind: .microphone)
        let mediaSession = StubMediaSession(tracks: [microphone])
        let receiver = LinkReceiverSession(session: mediaSession)
        receiver.isAudioSubscriptionEnabled = true

        try await receiver.connect(configuration: configuration)
        try await settle()

        XCTAssertNil(receiver.selectedVideoTrack)
        XCTAssertEqual(receiver.selectedAudioTrack, microphone.selectionID)
        XCTAssertEqual(mediaSession.subscribed, [microphone.id])
    }

    func testMutedSelectedCameraHandsOffThenClearsWithoutCachingADeadSelection() async throws {
        let cameraA = track("camera-a", participant: "a", name: "A", kind: .camera)
        let cameraB = track("camera-b", participant: "b", name: "B", kind: .camera)
        let mediaSession = StubMediaSession(tracks: [cameraA, cameraB])
        let duplex = LinkDuplexSession(session: mediaSession)
        var selections: [MediaTrackSelectionID?] = []
        duplex.onSelectedVideoTrackChanged = { selections.append($0) }

        try await duplex.connect(configuration: configuration)
        try await settle()
        XCTAssertEqual(selections.last!, cameraA.selectionID)

        mediaSession.emitTracks([muted(cameraA), cameraB])
        try await settle()
        XCTAssertEqual(selections.last!, cameraB.selectionID,
                       "the remaining active camera must replace a muted selection")
        XCTAssertEqual(mediaSession.activeSubscriptions, Set([cameraB.id]),
                       "handoff must release A instead of decoding two cameras")

        mediaSession.emitTracks([muted(cameraA), muted(cameraB)])
        try await settle()
        XCTAssertNil(selections.last!, "no active remote camera must be represented as nil")
        XCTAssertTrue(mediaSession.activeSubscriptions.isEmpty,
                      "all-muted must leave no remote media subscribed")

        mediaSession.emitTracks([cameraA, cameraB])
        try await settle()
        XCTAssertEqual(selections.last!, cameraA.selectionID,
                       "after an empty selection, deterministic track order breaks a tie")
    }

    func testApplicationOwnedCallAudioDisablesEveryLiveKitProcessingStage() {
        let policy = LinkApplicationAudioProcessingPolicy.unprocessed

        XCTAssertFalse(policy.echoCancellation)
        XCTAssertFalse(policy.autoGainControl)
        XCTAssertFalse(policy.noiseSuppression)
        XCTAssertFalse(policy.highpassFilter)
        XCTAssertFalse(policy.typingNoiseDetection)
    }

    func testExplicitVideoChoiceMovesAudioToSameParticipantAndRoutesOnlySelection() async throws {
        let cameraA = track("camera-a", participant: "a", name: "A", kind: .camera)
        let microphoneA = track("microphone-a", participant: "a", name: "A", kind: .microphone)
        let cameraB = track("camera-b", participant: "b", name: "B", kind: .camera)
        let microphoneB = track("microphone-b", participant: "b", name: "B", kind: .microphone)
        let mediaSession = StubMediaSession(tracks: [cameraA, microphoneA, cameraB, microphoneB])
        let receiver = LinkReceiverSession(session: mediaSession)
        receiver.isAudioSubscriptionEnabled = true
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
        receiver.isAudioSubscriptionEnabled = true
        try await receiver.connect(configuration: configuration)
        await receiver.disconnect()
        XCTAssertEqual(receiver.state, .idle)
        XCTAssertEqual(receiver.remoteTracks, [])
        XCTAssertTrue(mediaSession.didDisconnect)
        XCTAssertNil(mediaSession.publishedSource, "Receiver foundation must never open or publish a camera")
        XCTAssertEqual(mediaSession.microphoneValues, [], "Receiver foundation must never open a microphone")
    }

    func testDuplexForwardsReceiverStateChanges() async throws {
        let mediaSession = StubMediaSession(tracks: [])
        let duplex = LinkDuplexSession(session: mediaSession)
        var seen: [SessionState] = []
        duplex.onStateChanged = { seen.append($0) }
        try await duplex.connect(configuration: configuration)
        XCTAssertTrue(seen.contains(.connecting), "duplex must forward the receiver's state stream")
        XCTAssertEqual(duplex.state, .connected)
    }

    func testDuplexForwardsCameraPublishEnable() async throws {
        let mediaSession = StubMediaSession(tracks: [])
        let duplex = LinkDuplexSession(session: mediaSession)
        try await duplex.setCameraPublishEnabled(false)
        try await duplex.setCameraPublishEnabled(true)
        XCTAssertEqual(mediaSession.cameraPublishValues, [false, true])
    }

    func testDuplexForwardsRuntimeMicrophoneMute() async throws {
        let mediaSession = StubMediaSession(tracks: [])
        let duplex = LinkDuplexSession(session: mediaSession)
        try await duplex.setMicrophoneEnabled(false)
        try await duplex.setMicrophoneEnabled(true)
        XCTAssertEqual(mediaSession.microphoneValues, [false, true])
    }

    func testRemotePlaybackMuteForwardsThroughSessionAndDuplex() async throws {
        let client = LinkLiveKitClientSpy()
        let session = LiveKitMediaSession(client: client)
        session.setRemotePlaybackMuted(true)
        session.setRemotePlaybackMuted(false)
        XCTAssertEqual(client.remotePlaybackMutedValues, [true, false])

        let duplexClient = LinkLiveKitClientSpy()
        let duplex = LinkDuplexSession(session: LiveKitMediaSession(client: duplexClient))
        duplex.setRemotePlaybackMuted(true)
        XCTAssertEqual(duplexClient.remotePlaybackMutedValues, [true])
    }

    private var configuration: SessionConfiguration {
        SessionConfiguration(serverURL: URL(string: "wss://example.invalid"), roomName: "room", displayName: "iPad", accessToken: "runtime-token")
    }

    private func track(_ id: String, participant: String, name: String, kind: MediaTrackKind) -> RemoteMediaTrack {
        RemoteMediaTrack(id: .init(rawValue: id), participantID: .init(rawValue: participant), participantName: name, kind: kind, isMuted: false)
    }

    private func muted(_ track: RemoteMediaTrack) -> RemoteMediaTrack {
        RemoteMediaTrack(
            id: track.id,
            participantID: track.participantID,
            participantName: track.participantName,
            kind: track.kind,
            isMuted: true
        )
    }

    // Subscribes run on fire-and-forget tasks that hop executors; give them
    // real time plus main-actor yields so every enqueued task completes.
    private func settle() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(nanoseconds: 100_000_000)
        for _ in 0..<20 { await Task.yield() }
    }

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

private final class LinkLiveKitClientSpy: LiveKitClient {
    var remotePlaybackMutedValues: [Bool] = []
    func setRemotePlaybackMuted(_ muted: Bool) { remotePlaybackMutedValues.append(muted) }
    var onStateChanged: ((LiveKitClientState) -> Void)?
    var onTracksChanged: (([LiveKitTrackDescriptor]) -> Void)?
    var onVideoFrame: ((String, CVPixelBuffer, CMTime) -> Void)?
    var onAudioFrame: (@Sendable (String, AVAudioPCMBuffer) -> Void)?
    var publishedFrameTimes: [CMTime] = []
    var capturedAudioCount = 0
    var cameraPublishValues: [Bool] = []

    func connect(serverURL: URL, token: String) async throws { onStateChanged?(.connected) }
    func publishCamera(firstFrame: CVPixelBuffer, presentationTime: CMTime) async throws {
        publishedFrameTimes.append(presentationTime)
    }
    func capture(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        publishedFrameTimes.append(presentationTime)
    }
    func captureAudio(_ sampleBuffer: CMSampleBuffer) { capturedAudioCount += 1 }
    func setMicrophoneEnabled(_ enabled: Bool) async throws {}
    func setCameraPublishEnabled(_ enabled: Bool) async throws { cameraPublishValues.append(enabled) }
    func subscribe(to trackID: String) async throws {}
    func unsubscribe(from trackID: String) async throws {}
    func disconnect() async {}
}

private final class StubMediaSession: MediaSession {
    var state: SessionState = .idle
    var remoteTracks: [RemoteMediaTrack]
    var onStateChanged: ((SessionState) -> Void)?
    var onRemoteTracksChanged: (([RemoteMediaTrack]) -> Void)?
    var onRemoteVideoFrame: ((MediaTrackID, CMSampleBuffer) -> Void)?
    var onRemoteAudio: ((MediaTrackID, CMSampleBuffer) -> Void)?
    var subscribed: [MediaTrackID] = []
    var unsubscribed: [MediaTrackID] = []
    var activeSubscriptions = Set<MediaTrackID>()
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
    var cameraPublishValues: [Bool] = []
    func setCameraPublishEnabled(_ enabled: Bool) async throws { cameraPublishValues.append(enabled) }
    // Concurrent fire-and-forget subscribe tasks land here off the main actor;
    // hop the append to main so appends can't race each other or the test's read.
    func subscribe(to trackID: MediaTrackID) async throws {
        await MainActor.run {
            subscribed.append(trackID)
            activeSubscriptions.insert(trackID)
        }
    }
    func unsubscribe(from trackID: MediaTrackID) async throws {
        await MainActor.run {
            unsubscribed.append(trackID)
            activeSubscriptions.remove(trackID)
        }
    }
    func disconnect() async { didDisconnect = true; state = .idle }
    func currentStats() -> TransportStats? { nil }
    func emitTracks(_ tracks: [RemoteMediaTrack]) {
        remoteTracks = tracks
        onRemoteTracksChanged?(tracks)
    }
}
