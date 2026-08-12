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
    var onAudioFrame: ((_ trackID: String, _ pcmBuffer: AVAudioPCMBuffer) -> Void)? { get set }
    func connect(serverURL: URL, token: String) async throws
    func publishCamera(firstFrame: CVPixelBuffer, presentationTime: CMTime) async throws
    func capture(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime)
    func setMicrophoneEnabled(_ enabled: Bool) async throws
    func subscribe(to trackID: String) async throws
    func disconnect() async
}

/// LiveKit implementation of the product-owned media-session contract.
///
/// Video stays application-owned: `CameraManager` feeds one `LocalMediaSource`, and
/// this adapter forwards its buffers. LiveKit 2.16's public high-level microphone API
/// owns network microphone capture when enabled. Source audio remains available to the
/// app recorder and is not falsely reported as published by this adapter.
final class LiveKitMediaSession: MediaSession {
    enum ConfigurationError: Error, Equatable { case missingServerURL, missingAccessToken, unknownTrack }
    enum AudioCaptureOwnership: Equatable { case liveKitSDK }
    let audioCaptureOwnership: AudioCaptureOwnership = .liveKitSDK

    private let client: LiveKitClient
    private let mediaQueue = DispatchQueue(label: "StageGlassLink.LiveKitMediaSession.Media", qos: .userInteractive)
    private let lock = NSLock()
    private var storedState: SessionState = .idle
    private var storedRemoteTracks: [RemoteMediaTrack] = []
    private var sourceSubscription: LocalMediaSource.Subscription?
    private var connected = false
    private var cameraPublished = false
    private var cameraPublishInFlight = false
    private var generation: UInt64 = 0
    private var remoteAudioPTS: [String: CMTime] = [:]

    var onStateChanged: ((SessionState) -> Void)?
    var onRemoteTracksChanged: (([RemoteMediaTrack]) -> Void)?
    var onRemoteVideoFrame: ((MediaTrackID, CMSampleBuffer) -> Void)?
    var onRemoteAudio: ((MediaTrackID, CMSampleBuffer) -> Void)?

    init(client: LiveKitClient = LiveKitSDKClient()) {
        self.client = client
        wireClientCallbacks()
    }

    var state: SessionState { lock.withLock { storedState } }
    var remoteTracks: [RemoteMediaTrack] { lock.withLock { storedRemoteTracks } }

    func connect(configuration: SessionConfiguration) async throws {
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

    func publishCamera(_ source: LocalMediaSource) async throws {
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
            onAudioSampleBuffer: { _ in
                // Recorder consumes source audio; LiveKit SDK owns network mic capture.
            }
        )
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws { try await client.setMicrophoneEnabled(enabled) }

    func subscribe(to trackID: MediaTrackID) async throws {
        guard remoteTracks.contains(where: { $0.id == trackID }) else { throw ConfigurationError.unknownTrack }
        try await client.subscribe(to: trackID.rawValue)
    }

    func disconnect() async {
        sourceSubscription?.cancel()
        sourceSubscription = nil
        lock.withLock {
            generation &+= 1
            connected = false
            cameraPublished = false
            cameraPublishInFlight = false
            storedRemoteTracks = []
            storedState = .idle
        }
        await client.disconnect()
        notifyTracks([])
        notifyState(.idle)
    }

    func currentStats() -> TransportStats? { nil }

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
              let channels = buffer.floatChannelData,
              buffer.format.channelCount > 0,
              buffer.frameLength > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var interleaved = [Float](repeating: 0, count: channelCount * frameCount)
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                interleaved[frame * channelCount + channel] = channels[channel][frame]
            }
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
                lock.withLock {
                    guard connected, generation == expectedGeneration else { return }
                    cameraPublished = true
                    cameraPublishInFlight = false
                }
            } catch {
                lock.withLock { cameraPublishInFlight = false }
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
