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

    public func disconnect() async {
        await receiver.disconnect()
    }
}
