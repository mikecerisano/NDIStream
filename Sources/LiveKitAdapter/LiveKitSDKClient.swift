import AVFoundation
import CoreMedia
import Foundation
import LiveKit

/// Thin boundary around LiveKit. Product/session code must not expose LiveKit types.
///
/// This client deliberately accepts the application's existing pixel buffers instead
/// of asking LiveKit to open another camera capture session.
/// Process-wide publish tuning the HOST APP sets BEFORE a client (Room) is
/// created (quality picker, Aug 27). Read once at Room creation.
public enum LinkStreamPublishTuning {
    public static var maxVideoBitrate: Int = 1_700_000
}

/// The call publishes application-owned PCM from the same AVCapture graph
/// that records the local ISO. Speakerphone operation still needs echo
/// cancellation, but Apple's coupled voice-processing path and LiveKit's
/// default AGC may change the physical system microphone gain underneath the
/// raw ISO recorder. Force WebRTC's software AEC only; keep every level- or
/// tone-changing stage off. The ISO tap occurs before this call-only policy.
struct LinkApplicationAudioProcessingPolicy: Equatable, Sendable {
    let echoCancellation: Bool
    let autoGainControl: Bool
    let noiseSuppression: Bool
    let highpassFilter: Bool
    let typingNoiseDetection: Bool

    static let speakerphoneSafe = LinkApplicationAudioProcessingPolicy(
        echoCancellation: true,
        autoGainControl: false,
        noiseSuppression: false,
        highpassFilter: false,
        typingNoiseDetection: false
    )

    var captureOptions: AudioCaptureOptions {
        AudioCaptureOptions(
            echoCancellation: echoCancellation,
            autoGainControl: autoGainControl,
            noiseSuppression: noiseSuppression,
            highpassFilter: highpassFilter,
            typingNoiseDetection: typingNoiseDetection,
            echoCancellationMode: .software,
            autoGainControlMode: .software,
            noiseSuppressionMode: .software,
            highpassFilterMode: .software
        )
    }
}

final class LiveKitSDKClient: NSObject, LiveKitClient, @unchecked Sendable {
    /// LiveKit Swift 2.16 cannot accept the application's existing microphone
    /// sample buffers. Keep microphone capture ownership explicit so we never
    /// silently open a competing second capture graph.
    enum MicrophoneCaptureOwnership: Equatable, Sendable {
        case application
        case liveKit
    }

    var onStateChanged: ((LiveKitClientState) -> Void)?
    var onTracksChanged: (([LiveKitTrackDescriptor]) -> Void)?
    var onVideoFrame: ((_ trackID: String, _ pixelBuffer: CVPixelBuffer, _ presentationTime: CMTime) -> Void)?
    var onAudioFrame: (@Sendable (_ trackID: String, _ pcmBuffer: AVAudioPCMBuffer) -> Void)?

    private let room: Room
    private let lock = NSLock()
    private var cameraTrack: LocalVideoTrack?
    private var cameraCapturer: BufferCapturer?
    private var desiredCameraPublishEnabled = true
    private var cameraPublishIntentGeneration: UInt64 = 0
    private var renderers: [String: PixelBufferRenderer] = [:]
    private var audioRenderers: [String: PCMBufferRenderer] = [:]
    private let microphoneCaptureOwnership: MicrophoneCaptureOwnership
    /// Operator mute for REMOTE playback (the peer's voice). Applied to every
    /// current remote audio track and re-applied to late subscriptions.
    private var remotePlaybackMuted = false

    var usesSDKMicrophoneCapture: Bool { microphoneCaptureOwnership == .liveKit }

    /// One explicit publish profile for the Link call leg (StageGlass
    /// thermal-livekit plan, Aug 24, triple-approved). The SDK's defaults
    /// otherwise govern — and `VideoPublishOptions.simulcast` defaults to
    /// TRUE, which had a phone running parallel encoders for a one-viewer
    /// call (field thermal SERIOUS at ~3min with liveKitPublish the only
    /// active pipeline). Single H.264 layer, capped, framerate preferred;
    /// adaptiveStream/dynacast pinned false explicitly so an SDK default
    /// change can never re-enable them. Speech-preset audio (24 kbps Opus)
    /// matches the call leg this client publishes.
    /// NOTE: whether AudioPublishOptions governs the application-ownership
    /// mixer-injected track in this SDK build is unverified (plan
    /// uninspectable); the option is harmless if ignored.
    private static func callRoomOptions() -> RoomOptions {
        let applicationAudio = LinkApplicationAudioProcessingPolicy.speakerphoneSafe
        return RoomOptions(
            defaultAudioCaptureOptions: applicationAudio.captureOptions,
            defaultVideoPublishOptions: VideoPublishOptions(
                // 1.7 Mbps paired with the app-side 720p short-edge cap on
                // published frames (Aug 27 quality ruling): bits the encoder
                // can hold at 720p, replacing starved 1080p that collapsed
                // under motion at 800k. Still single-layer H.264 — the Aug 24
                // thermal defect was simulcast's parallel encoders, not rate.
                encoding: VideoEncoding(maxBitrate: LinkStreamPublishTuning.maxVideoBitrate, maxFps: 24),
                simulcast: false,
                preferredCodec: .h264,
                degradationPreference: .maintainFramerate
            ),
            defaultAudioPublishOptions: AudioPublishOptions(
                encoding: .presetSpeech
            ),
            adaptiveStream: false,
            dynacast: false,
            // Sender/receiver stats for the thermal ladder's mandatory
            // peer-side measurement (plan DELTA 4.3).
            reportRemoteTrackStatistics: true
        )
    }

    init(microphoneCaptureOwnership: MicrophoneCaptureOwnership = .application) {
        self.microphoneCaptureOwnership = microphoneCaptureOwnership
        // Single-session-owner law (StageGlass, Aug 27): the SDK must NEVER
        // touch AVAudioSession — the host app owns it exclusively. Two
        // independent mechanisms, both unconditional (publisher AND receiver;
        // previously manual rendering was set only inside
        // setMicrophoneEnabled(true), so a receiver auto-subscribing a peer
        // mic ran the SDK's real playout engine and its session observer
        // configured + setActive'd per track change — the churn class that
        // watchdog-crashed audiomxd):
        // 1. Manual rendering — the engine takes no device path, remote audio
        //    reaches the app only via explicit track renderers.
        // 2. Automatic session configuration off — the session observer's
        //    configure path is a total no-op even if an engine state slips.
        if microphoneCaptureOwnership == .application {
            // Fail closed against Apple Voice Processing I/O. Software AEC
            // receives the far-end playout reference without letting the OS
            // couple echo cancellation back to hardware AGC/input gain.
            try? AudioManager.shared.setPlatformVoiceProcessingAllowed(false)
            // NORMAL engine mode (Aug 28 field fix, codex-verified in 2.16
            // source): manual rendering is UNSHIPPABLE here — the SDK's own
            // tests pin the engine as non-running in manual mode, so
            // mixer.capture(appAudio:) drops every buffer (silent published
            // track) and no public call bridges the gap. Instead:
            // - session config stays OFF (the app owns AVAudioSession; the
            //   churn class stays dead),
            // - the normal engine runs and SDK PLAYOUT is the speaker path
            //   for remote audio (the app must NOT also play frames),
            // - the device-mic contribution is muted at the mixer so ONLY
            //   app-injected audio reaches the published track.
            #if os(iOS)
            AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
            #endif
            try? AudioManager.shared.set(microphoneMuteMode: .inputMixer)
            AudioManager.shared.mixer.micVolume = 0
            AudioManager.shared.mixer.appVolume = 1
        }
        room = Room(roomOptions: Self.callRoomOptions())
        super.init()
        room.add(delegate: self)
    }

    deinit {
        room.remove(delegate: self)
    }

    func connect(serverURL: URL, token: String) async throws {
        emit(.connecting)
        do {
            try await room.connect(url: serverURL.absoluteString, token: token)
            emit(.connected)
            emitTracks()
        } catch {
            let safeMessage = Self.redactedDescription(of: error, token: token)
            emit(.failed(safeMessage))
            throw ConnectionError(message: safeMessage)
        }
    }

    /// Supplies the first frame and publishes one application-owned camera track.
    /// LiveKit needs a frame before publish so it can determine encoding dimensions.
    func publishCamera(firstFrame: CVPixelBuffer, presentationTime: CMTime) async throws {
        if lock.withLock({ cameraTrack != nil }) {
            capture(firstFrame, presentationTime: presentationTime)
            return
        }

        let track = LocalVideoTrack.createBufferTrack(
            name: Track.cameraName,
            source: .camera,
            options: BufferCaptureOptions()
        )
        guard let capturer = track.capturer as? BufferCapturer else {
            throw ConnectionError(message: "Live video capture could not be created.")
        }

        capturer.capture(firstFrame, timeStampNs: Self.nanoseconds(for: presentationTime))
        lock.withLock {
            cameraTrack = track
            cameraCapturer = capturer
        }
        do {
            // Apply camera-off before publication when possible, then again
            // after the suspending publish call. The reconciliation loop is
            // generation-checked, so a concurrent operator flip always wins.
            try await reconcileCameraPublishIntent(on: track)
            _ = try await room.localParticipant.publish(videoTrack: track)
            try await reconcileCameraPublishIntent(on: track)
        } catch {
            lock.withLock {
                guard cameraTrack === track else { return }
                cameraTrack = nil
                cameraCapturer = nil
            }
            throw error
        }
    }

    func capture(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        cameraCapturer?.capture(pixelBuffer, timeStampNs: Self.nanoseconds(for: presentationTime))
    }

    func captureAudio(_ sampleBuffer: CMSampleBuffer) {
        guard microphoneCaptureOwnership == .application,
              let buffer = Self.makePCMBuffer(from: sampleBuffer) else { return }
        AudioManager.shared.mixer.capture(appAudio: buffer)
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        // Manual rendering + automatic-configuration-off are set once in
        // `init` for application ownership. CRITICAL (field silence, Aug 28):
        // publishing the mic track is NOT enough — in manual rendering the
        // SDK's audio engine never starts on its own, and
        // `mixer.capture(appAudio:)` drops every buffer against a stopped
        // engine ("Engine is not running"), leaving a healthy-LOOKING but
        // SILENT published track. `startLocalRecording()` starts the ADM
        // recording path, which brings the engine up in manual mode (no
        // device IO, no AVAudioSession touch — the session observer skips
        // both in manual rendering).
        // Normal engine mode: setMicrophone drives the full lifecycle
        // (engine start, recording, playout). App audio is injected via
        // mixer.capture; the device-mic path is muted at the mixer (init).
        try await room.localParticipant.setMicrophone(enabled: enabled)
    }

    func subscribe(to trackID: String) async throws {
        guard let publication = remotePublication(withID: trackID) else {
            throw ConnectionError(message: "The selected remote track is no longer available.")
        }
        try await publication.set(subscribed: true)
        attachRendererIfNeeded(to: publication)
    }

    func unsubscribe(from trackID: String) async throws {
        guard let publication = remotePublication(withID: trackID) else {
            // A departed publication is already unsubscribed by definition.
            lock.withLock {
                renderers.removeValue(forKey: trackID)
                audioRenderers.removeValue(forKey: trackID)
            }
            return
        }
        if let track = publication.track as? RemoteVideoTrack,
           let renderer = lock.withLock({ renderers.removeValue(forKey: trackID) }) {
            track.remove(videoRenderer: renderer)
        }
        if let track = publication.track as? RemoteAudioTrack {
            track.volume = 0
            if let renderer = lock.withLock({ audioRenderers.removeValue(forKey: trackID) }) {
                track.remove(audioRenderer: renderer)
            }
        }
        try await publication.set(subscribed: false)
    }

    func disconnect() async {
        lock.withLock {
            renderers.removeAll()
            audioRenderers.removeAll()
            cameraTrack = nil
            cameraCapturer = nil
            desiredCameraPublishEnabled = true
            cameraPublishIntentGeneration &+= 1
        }
        await room.disconnect()
        emit(.idle)
        onTracksChanged?([])
    }

    static func redactedDescription(of error: Error, token: String) -> String {
        let raw = String(describing: error)
        guard !token.isEmpty else { return raw }
        return raw.replacingOccurrences(of: token, with: "<redacted>")
    }

    func setCameraPublishEnabled(_ enabled: Bool) async throws {
        let track = lock.withLock { () -> LocalVideoTrack? in
            desiredCameraPublishEnabled = enabled
            cameraPublishIntentGeneration &+= 1
            return cameraTrack
        }
        guard let track else { return }
        try await reconcileCameraPublishIntent(on: track)
    }

    private func reconcileCameraPublishIntent(on track: LocalVideoTrack) async throws {
        while true {
            let snapshot = lock.withLock {
                (desiredCameraPublishEnabled, cameraPublishIntentGeneration, cameraTrack === track)
            }
            guard snapshot.2 else { return }
            if snapshot.0 {
                try await track.unmute()
            } else {
                try await track.mute()
            }
            let isCurrent = lock.withLock {
                cameraTrack === track && cameraPublishIntentGeneration == snapshot.1
            }
            if isCurrent { return }
        }
    }

    func setRemotePlaybackMuted(_ muted: Bool) {
        // Flag update and volume application are ONE critical section: a late
        // attach that read the old flag must not write a stale volume after an
        // operator flip (attach's volume write holds this same lock).
        lock.withLock {
            remotePlaybackMuted = muted
            for participant in room.remoteParticipants.values {
                for publication in participant.trackPublications.values {
                    if let track = publication.track as? RemoteAudioTrack {
                        track.volume = muted ? 0 : 1
                    }
                }
            }
        }
    }

    private func remotePublication(withID id: String) -> RemoteTrackPublication? {
        room.remoteParticipants.values
            .flatMap(\.trackPublications.values)
            .compactMap { $0 as? RemoteTrackPublication }
            .first { $0.sid.stringValue == id }
    }

    private func emit(_ state: LiveKitClientState) {
        onStateChanged?(state)
    }

    private func emitTracks() {
        let tracks = room.remoteParticipants.values.flatMap { participant in
            participant.trackPublications.values.map { publication in
                LiveKitTrackDescriptor(
                    id: publication.sid.stringValue,
                    participantID: participant.identity?.stringValue ?? participant.sid?.stringValue ?? "unknown",
                    participantName: participant.name ?? participant.identity?.stringValue ?? "Remote",
                    kind: Self.kind(for: publication.source),
                    isMuted: publication.isMuted
                )
            }
        }.sorted { lhs, rhs in
            if lhs.participantID == rhs.participantID { return lhs.id < rhs.id }
            return lhs.participantID < rhs.participantID
        }
        onTracksChanged?(tracks)
    }

    private func attachRendererIfNeeded(to publication: RemoteTrackPublication) {
        let trackID = publication.sid.stringValue
        if let track = publication.track as? RemoteVideoTrack {
            let renderer: PixelBufferRenderer = lock.withLock {
                if let existing = renderers[trackID] { return existing }
                let created = PixelBufferRenderer(trackID: trackID) { [weak self] id, pixelBuffer, pts in
                    self?.onVideoFrame?(id, pixelBuffer, pts)
                }
                renderers[trackID] = created
                return created
            }
            track.add(videoRenderer: renderer)
        } else if let track = publication.track as? RemoteAudioTrack {
            // Same critical section as setRemotePlaybackMuted: read + apply
            // atomically so a concurrent operator flip can't be overwritten
            // with a stale value.
            lock.withLock { track.volume = remotePlaybackMuted ? 0 : 1 }
            let renderer: PCMBufferRenderer = lock.withLock {
                if let existing = audioRenderers[trackID] { return existing }
                let created = PCMBufferRenderer(trackID: trackID) { [weak self] id, buffer in
                    self?.onAudioFrame?(id, buffer)
                }
                audioRenderers[trackID] = created
                return created
            }
            track.add(audioRenderer: renderer)
        }
    }

    private static func kind(for source: Track.Source) -> LiveKitTrackDescriptor.Kind {
        switch source {
        case .camera: .camera
        case .microphone: .microphone
        case .screenShareVideo, .screenShareAudio: .screenShare
        case .unknown: .unknown
        }
    }

    private static func nanoseconds(for time: CMTime) -> Int64 {
        guard time.isNumeric else { return VideoCapturer.createTimeStampNs() }
        return Int64((time.seconds * 1_000_000_000).rounded())
    }

    static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.pointee.mBitsPerChannel == 32,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let channels = Int(asbd.pointee.mChannelsPerFrame)
        guard frames > 0, channels > 0 else { return nil }
        let interleaved = asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard interleaved else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: interleaved
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &pointer
        ) == noErr, let pointer else { return nil }
        let bytes = min(length, frames * channels * MemoryLayout<Float>.size)
        if let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData {
            memcpy(destination, pointer, bytes)
            buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(bytes)
            return buffer
        }
        return nil
    }
}

extension LiveKitSDKClient: RoomDelegate {
    nonisolated func room(
        _ room: Room,
        didUpdateConnectionState connectionState: ConnectionState,
        from oldConnectionState: ConnectionState
    ) {
        switch connectionState {
        case .disconnected: emit(.idle)
        case .connecting: emit(.connecting)
        case .connected: emit(.connected)
        case .reconnecting, .disconnecting: emit(.reconnecting)
        @unknown default: emit(.failed("The Link connection entered an unknown state."))
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        emitTracks()
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        emitTracks()
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        emitTracks()
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        _ = lock.withLock {
            renderers.removeValue(forKey: publication.sid.stringValue)
            audioRenderers.removeValue(forKey: publication.sid.stringValue)
        }
        emitTracks()
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        attachRendererIfNeeded(to: publication)
        emitTracks()
    }

    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        emitTracks()
    }
}

private final class PCMBufferRenderer: NSObject, AudioRenderer, @unchecked Sendable {
    let trackID: String
    private let onFrame: @Sendable (String, AVAudioPCMBuffer) -> Void

    init(trackID: String, onFrame: @escaping @Sendable (String, AVAudioPCMBuffer) -> Void) {
        self.trackID = trackID
        self.onFrame = onFrame
    }

    nonisolated func render(pcmBuffer: AVAudioPCMBuffer) {
        onFrame(trackID, pcmBuffer)
    }
}

extension LiveKitSDKClient {
    struct ConnectionError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }
}

private final class PixelBufferRenderer: NSObject, VideoRenderer, @unchecked Sendable {
    let trackID: String
    private let onFrame: @Sendable (String, CVPixelBuffer, CMTime) -> Void

    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }

    init(trackID: String, onFrame: @escaping @Sendable (String, CVPixelBuffer, CMTime) -> Void) {
        self.trackID = trackID
        self.onFrame = onFrame
    }

    nonisolated func render(frame: VideoFrame) {
        let pixelBuffer: CVPixelBuffer?
        if let cvBuffer = frame.buffer as? CVPixelVideoBuffer {
            pixelBuffer = cvBuffer.pixelBuffer
        } else if let i420Buffer = frame.buffer as? I420VideoBuffer {
            pixelBuffer = i420Buffer.toPixelBuffer()
        } else {
            pixelBuffer = nil
        }
        guard let pixelBuffer else { return }
        let pts = CMTime(value: frame.timeStampNs, timescale: 1_000_000_000)
        onFrame(trackID, pixelBuffer, pts)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
