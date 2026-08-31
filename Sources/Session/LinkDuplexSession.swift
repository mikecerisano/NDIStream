import CoreMedia
import Foundation

/// Platform-neutral StageGlass Link session for an endpoint that may publish,
/// subscribe, or do both according to its short-lived credential.
@MainActor
public final class LinkDuplexSession {
    public var onVideoFrame: ((MediaTrackID, CMSampleBuffer) -> Void)? {
        didSet { receiver.onVideoFrame = onVideoFrame }
    }
    public var onAudioFrame: ((MediaTrackID, CMSampleBuffer) -> Void)? {
        didSet { receiver.onAudioFrame = onAudioFrame }
    }
    public var onSelectedVideoTrackChanged: ((MediaTrackSelectionID?) -> Void)? {
        didSet { receiver.onSelectedVideoTrackChanged = onSelectedVideoTrackChanged }
    }

    /// Forwarded receiver state — the Mac call owner's `connectionPhase`
    /// source (video-chat plan v2: `LinkDuplexSession` exposed no state at
    /// all, which made reconnect UI unbuildable — plan review finding).
    public var onStateChanged: ((SessionState) -> Void)? {
        didSet { receiver.onStateChanged = onStateChanged }
    }
    public var state: SessionState { receiver.state }

    private let session: MediaSession
    private let receiver: LinkReceiverSession

    public init(session: MediaSession = LiveKitMediaSession()) {
        self.session = session
        receiver = LinkReceiverSession(session: session)
    }

    /// Forwarded receiver gate: whether the peer's microphone track is
    /// auto-subscribed. Default false — the host app opts in from its
    /// receivesAudio decision (see LinkReceiverSession.isAudioSubscriptionEnabled).
    public var isAudioSubscriptionEnabled: Bool {
        get { receiver.isAudioSubscriptionEnabled }
        set { receiver.isAudioSubscriptionEnabled = newValue }
    }

    public func connect(configuration: SessionConfiguration) async throws {
        try await receiver.connect(configuration: configuration)
    }

    public func publish(_ source: LocalMediaSource, microphoneEnabled: Bool) async throws {
        try await session.publishCamera(source)
        try await session.setMicrophoneEnabled(microphoneEnabled)
    }

    /// Operator mute for the peer's voice playback (remote SDK playout).
    public func setRemotePlaybackMuted(_ muted: Bool) {
        session.setRemotePlaybackMuted(muted)
    }

    /// Runtime LOCAL-mic mute for a live publication — the Mac call owner's
    /// transport-level mute (the peer receives silence; plan v2 finding: the
    /// old desktop mute flipped UI state only).
    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        try await session.setMicrophoneEnabled(enabled)
    }

    /// Runtime camera pause for a live publication (peer sees video stop) —
    /// the Mac call owner's setCameraEnabled projection.
    public func setCameraPublishEnabled(_ enabled: Bool) async throws {
        try await session.setCameraPublishEnabled(enabled)
    }

    public func disconnect() async {
        await receiver.disconnect()
    }
}
