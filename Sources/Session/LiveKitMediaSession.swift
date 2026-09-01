import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum LiveKitClientState: Equatable { case idle, connecting, connected, reconnecting, failed(String) }

struct LiveKitTrackDescriptor: Equatable {
    enum Kind: Equatable { case camera, microphone, screenShare, unknown }
    let id: String
    let participantID: String
    let participantName: String
    let kind: Kind
    let isMuted: Bool
}

/// Testable boundary around the third-party SDK. LiveKit types stop here.
protocol LiveKitClient: AnyObject {
    var onStateChanged: ((LiveKitClientState) -> Void)? { get set }
    var onTracksChanged: (([LiveKitTrackDescriptor]) -> Void)? { get set }
    var onVideoFrame: ((_ trackID: String, _ pixelBuffer: CVPixelBuffer, _ presentationTime: CMTime) -> Void)? { get set }
    var onAudioFrame: (@Sendable (_ trackID: String, _ pcmBuffer: AVAudioPCMBuffer) -> Void)? { get set }
    func connect(serverURL: URL, token: String) async throws
    func publishCamera(firstFrame: CVPixelBuffer, presentationTime: CMTime) async throws
    func capture(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime)
    func captureAudio(_ sampleBuffer: CMSampleBuffer)
    func setMicrophoneEnabled(_ enabled: Bool) async throws
    func setCameraPublishEnabled(_ enabled: Bool) async throws
    func setRemotePlaybackMuted(_ muted: Bool)
    func setRemotePlaybackGain(_ gain: Double)
    func subscribe(to trackID: String) async throws
    func unsubscribe(from trackID: String) async throws
    func disconnect() async
}

extension LiveKitClient {
    /// Optional for test doubles and adapters that do not expose subscribed audio.
    var onAudioFrame: (@Sendable (_ trackID: String, _ pcmBuffer: AVAudioPCMBuffer) -> Void)? {
        get { nil }
        set { }
    }
}

/// LiveKit implementation of the product-owned media-session contract.
///
/// Video stays application-owned: `CameraManager` feeds one `LocalMediaSource`, and
/// this adapter forwards its buffers. Application-owned microphone buffers are injected
/// through LiveKit's manual audio rendering input, so the SDK never opens a competing
/// microphone graph.
public final class LiveKitMediaSession: MediaSession {
    public enum ConfigurationError: Error, Equatable { case missingServerURL, missingAccessToken, unknownTrack }
    public enum AudioCaptureOwnership: Equatable { case application }
    public let audioCaptureOwnership: AudioCaptureOwnership = .application

    private let client: LiveKitClient
    private let mediaQueue = DispatchQueue(label: "StageGlassLink.LiveKitMediaSession.Media", qos: .userInteractive)
    private let lock = NSLock()
    private var storedState: SessionState = .idle
    private var storedRemoteTracks: [RemoteMediaTrack] = []
    private var sourceSubscription: LocalMediaSource.Subscription?
    private var connected = false
    private var cameraPublished = false
    private var cameraPublishInFlight = false
    private var desiredCameraPublishEnabled = true
    private var generation: UInt64 = 0
    private var remoteAudioPTS: [String: CMTime] = [:]

    public var onStateChanged: ((SessionState) -> Void)?
    public var onRemoteTracksChanged: (([RemoteMediaTrack]) -> Void)?
    public var onRemoteVideoFrame: ((MediaTrackID, CMSampleBuffer) -> Void)?
    public var onRemoteAudio: ((MediaTrackID, CMSampleBuffer) -> Void)?

    init(client: LiveKitClient) {
        self.client = client
        wireClientCallbacks()
    }

    public convenience init() {
        self.init(client: LiveKitSDKClient())
    }

    public var state: SessionState { lock.withLock { storedState } }
    public var remoteTracks: [RemoteMediaTrack] { lock.withLock { storedRemoteTracks } }

    public func connect(configuration: SessionConfiguration) async throws {
        guard let serverURL = configuration.serverURL else { throw ConfigurationError.missingServerURL }
        guard let token = configuration.accessToken, !token.isEmpty else { throw ConfigurationError.missingAccessToken }
        let currentGeneration = lock.withLock { () -> UInt64 in
            generation &+= 1
            connected = true
            storedState = .connecting
            return generation
        }
        notifyState(.connecting)
        do {
            try await client.connect(serverURL: serverURL, token: token)
        } catch {
            guard isCurrent(currentGeneration) else { throw error }
            let message = Self.redactedCredentialDescription(String(describing: error))
                .replacingOccurrences(of: token, with: "<redacted>")
            transition(to: .failed(message: message))
            throw LiveKitSDKClient.ConnectionError(message: message)
        }
    }

    public func publishCamera(_ source: LocalMediaSource) async throws {
        let currentGeneration = lock.withLock { generation }
        guard lock.withLock({ connected }) else {
            throw LiveKitSDKClient.ConnectionError(message: "Link is not connected.")
        }
        sourceSubscription?.cancel()
        sourceSubscription = source.subscribe(
            queue: mediaQueue,
            onVideoFrame: { [weak self] pixelBuffer, pts in
                self?.publish(pixelBuffer, presentationTime: pts, generation: currentGeneration)
            },
            onAudioSampleBuffer: { [weak self] sampleBuffer in
                self?.client.captureAudio(sampleBuffer)
            }
        )
    }

    public func setRemotePlaybackMuted(_ muted: Bool) {
        client.setRemotePlaybackMuted(muted)
    }

    public func setRemotePlaybackGain(_ gain: Double) {
        client.setRemotePlaybackGain(gain)
    }

    public func setMicrophoneEnabled(_ enabled: Bool) async throws { try await client.setMicrophoneEnabled(enabled) }
    public func setCameraPublishEnabled(_ enabled: Bool) async throws {
        lock.withLock { desiredCameraPublishEnabled = enabled }
        try await client.setCameraPublishEnabled(enabled)
    }

    public func subscribe(to trackID: MediaTrackID) async throws {
        guard remoteTracks.contains(where: { $0.id == trackID }) else { throw ConfigurationError.unknownTrack }
        try await client.subscribe(to: trackID.rawValue)
    }

    public func unsubscribe(from trackID: MediaTrackID) async throws {
        try await client.unsubscribe(from: trackID.rawValue)
    }

    public func disconnect() async {
        sourceSubscription?.cancel()
        sourceSubscription = nil
        lock.withLock {
            generation &+= 1
            connected = false
            cameraPublished = false
            cameraPublishInFlight = false
            desiredCameraPublishEnabled = true
            storedRemoteTracks = []
            storedState = .idle
        }
        await client.disconnect()
        notifyTracks([])
        notifyState(.idle)
    }

    public func currentStats() -> TransportStats? { nil }

    private func wireClientCallbacks() {
        client.onStateChanged = { [weak self] state in self?.receive(state) }
        client.onTracksChanged = { [weak self] tracks in self?.receive(tracks) }
        client.onVideoFrame = { [weak self] id, pixelBuffer, pts in
            self?.receiveVideo(trackID: id, pixelBuffer: pixelBuffer, presentationTime: pts)
        }
        client.onAudioFrame = { [weak self] id, buffer in
            self?.receiveAudio(trackID: id, buffer: buffer)
        }
    }

    private func receive(_ clientState: LiveKitClientState) {
        guard lock.withLock({ connected }) else { return }
        let mapped: SessionState = switch clientState {
        case .idle: .idle
        case .connecting: .connecting
        case .connected: .connected
        case .reconnecting: .reconnecting
        case let .failed(message): .failed(message: Self.redactedCredentialDescription(message))
        }
        transition(to: mapped)
    }

    private func receive(_ descriptors: [LiveKitTrackDescriptor]) {
        guard lock.withLock({ connected }) else { return }
        let tracks = descriptors.map { descriptor in
            RemoteMediaTrack(
                id: MediaTrackID(rawValue: descriptor.id),
                participantID: ParticipantID(rawValue: descriptor.participantID),
                participantName: descriptor.participantName,
                kind: Self.map(descriptor.kind),
                isMuted: descriptor.isMuted
            )
        }
        lock.withLock { storedRemoteTracks = tracks }
        notifyTracks(tracks)
    }

    private func receiveVideo(trackID: String, pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard lock.withLock({ connected }),
              let sampleBuffer = Self.makeVideoSampleBuffer(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onRemoteVideoFrame?(MediaTrackID(rawValue: trackID), sampleBuffer)
        }
    }

    private func receiveAudio(trackID: String, buffer: AVAudioPCMBuffer) {
        guard lock.withLock({ connected }),
              buffer.format.channelCount > 0,
              buffer.frameLength > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var interleaved = [Float](repeating: 0, count: channelCount * frameCount)

        // LiveKit/WebRTC's remote AudioRenderer currently supplies Int16,
        // non-interleaved PCM. The previous floatChannelData-only guard
        // therefore discarded every decoded partner buffer even while the
        // SDK's independent speaker playout remained perfectly audible. That
        // made application consumers (meters and monitor recording) report
        // "No audio" for a working call. Accept both WebRTC Int16 and Float32,
        // and normalize them into the transport's documented interleaved-float
        // CMSampleBuffer contract.
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { return }
            for channel in 0..<channelCount {
                let source = channels[buffer.format.isInterleaved ? 0 : channel]
                for frame in 0..<frameCount {
                    let sourceIndex = buffer.format.isInterleaved ? frame * channelCount + channel : frame
                    interleaved[frame * channelCount + channel] = source[sourceIndex]
                }
            }
        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { return }
            for channel in 0..<channelCount {
                let source = channels[buffer.format.isInterleaved ? 0 : channel]
                for frame in 0..<frameCount {
                    let sourceIndex = buffer.format.isInterleaved ? frame * channelCount + channel : frame
                    interleaved[frame * channelCount + channel] = Float(source[sourceIndex]) / 32768
                }
            }
        default:
            return
        }
        let sampleRate = Int32(buffer.format.sampleRate.rounded())
        let pts = lock.withLock { () -> CMTime in
            let current = remoteAudioPTS[trackID] ?? .zero
            remoteAudioPTS[trackID] = CMTimeAdd(current, CMTime(value: CMTimeValue(frameCount), timescale: sampleRate))
            return current
        }
        guard let sampleBuffer = AudioSampleBufferFactory.makeInterleavedFloat(
            samples: interleaved,
            sampleRate: sampleRate,
            channels: Int32(channelCount),
            presentationTime: pts
        ) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onRemoteAudio?(MediaTrackID(rawValue: trackID), sampleBuffer)
        }
    }

    private func publish(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, generation expectedGeneration: UInt64) {
        let action: Bool? = lock.withLock {
            guard connected, generation == expectedGeneration else { return nil }
            if cameraPublished { return true }
            guard !cameraPublishInFlight else { return nil }
            cameraPublishInFlight = true
            return false
        }
        guard let action else { return }
        if action {
            client.capture(pixelBuffer, presentationTime: presentationTime)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.publishCamera(firstFrame: pixelBuffer, presentationTime: presentationTime)
                // setCameraPublishEnabled(false) can arrive before the first
                // frame creates the SDK track. Re-apply the retained intent
                // immediately after publication so that call-site success
                // can never be lost at the lazy-track boundary.
                let desiredCameraPublishEnabled = self.lock.withLock {
                    self.desiredCameraPublishEnabled
                }
                try await self.client.setCameraPublishEnabled(desiredCameraPublishEnabled)
                self.lock.withLock {
                    guard self.connected, self.generation == expectedGeneration else { return }
                    self.cameraPublished = true
                    self.cameraPublishInFlight = false
                }
            } catch {
                self.lock.withLock { self.cameraPublishInFlight = false }
                guard isCurrent(expectedGeneration) else { return }
                transition(to: .failed(message: Self.redactedCredentialDescription(String(describing: error))))
            }
        }
    }

    private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        lock.withLock { connected && generation == expectedGeneration }
    }

    private func transition(to state: SessionState) {
        lock.withLock { storedState = state }
        notifyState(state)
    }

    private func notifyState(_ state: SessionState) {
        DispatchQueue.main.async { [weak self] in self?.onStateChanged?(state) }
    }

    private func notifyTracks(_ tracks: [RemoteMediaTrack]) {
        DispatchQueue.main.async { [weak self] in self?.onRemoteTracksChanged?(tracks) }
    }

    private static func map(_ kind: LiveKitTrackDescriptor.Kind) -> MediaTrackKind {
        switch kind { case .camera: .camera; case .microphone: .microphone; case .screenShare: .screenShare; case .unknown: .unknown }
    }

    private static func makeVideoSampleBuffer(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description) == noErr,
              let description else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    static func redactedCredentialDescription(_ message: String) -> String {
        let patterns = [#"(?i)(token\s*[=:]\s*)[^\s,;]+"#, #"(?i)(authorization\s*[=:]\s*(?:bearer\s+)?)[^\s,;]+"#]
        return patterns.reduce(message) { result, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return result }
            return expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1<redacted>")
        }
    }
}
