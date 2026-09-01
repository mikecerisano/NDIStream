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
        // Start LiveKit's microphone track (and therefore its AVAudioEngine)
        // before subscribing the application-owned media source. Subscribing
        // first lets live PCM arrive while LiveKit is still resetting and
        // starting MixerEngineObserver.appNode; AVAudioPlayerNode.play() then
        // raises an Objective-C exception instead of returning an Error. That
        // race was captured in a macOS crash report during a second-peer join.
        try await session.setMicrophoneEnabled(microphoneEnabled)
        try await session.publishCamera(source)
    }

    /// Operator mute for the peer's voice playback (remote SDK playout).
    public func setRemotePlaybackMuted(_ muted: Bool) {
        session.setRemotePlaybackMuted(muted)
    }

    /// Linear partner-speaker trim. The SDK adapter clamps this to 0...1.
    public func setRemotePlaybackGain(_ gain: Double) {
        session.setRemotePlaybackGain(gain)
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
