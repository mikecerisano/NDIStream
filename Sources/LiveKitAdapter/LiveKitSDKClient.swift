import AVFoundation
import CoreMedia
import Foundation
import LiveKit

/// Thin boundary around LiveKit. Product/session code must not expose LiveKit types.
///
/// This client deliberately accepts the application's existing pixel buffers instead
/// of asking LiveKit to open another camera capture session.
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
    private var renderers: [String: PixelBufferRenderer] = [:]
    private var audioRenderers: [String: PCMBufferRenderer] = [:]
    private let microphoneCaptureOwnership: MicrophoneCaptureOwnership

    init(microphoneCaptureOwnership: MicrophoneCaptureOwnership = .application) {
        self.microphoneCaptureOwnership = microphoneCaptureOwnership
        room = Room()
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
        if cameraTrack != nil {
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
        _ = try await room.localParticipant.publish(videoTrack: track)
        cameraTrack = track
        cameraCapturer = capturer
    }

    func capture(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        cameraCapturer?.capture(pixelBuffer, timeStampNs: Self.nanoseconds(for: presentationTime))
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        if enabled, microphoneCaptureOwnership == .application {
            throw ConnectionError(message: Self.externalMicrophoneCaptureMessage)
        }
        try await room.localParticipant.setMicrophone(enabled: enabled)
    }

    func subscribe(to trackID: String) async throws {
        guard let publication = remotePublication(withID: trackID) else {
            throw ConnectionError(message: "The selected remote track is no longer available.")
        }
        try await publication.set(subscribed: true)
        attachRendererIfNeeded(to: publication)
    }

    func disconnect() async {
        lock.withLock {
            renderers.removeAll()
            audioRenderers.removeAll()
            cameraTrack = nil
            cameraCapturer = nil
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

    static let externalMicrophoneCaptureMessage =
        "Microphone publishing is unavailable while StageGlass Link owns capture. LiveKit Swift 2.16 cannot accept the existing microphone buffers without opening a second capture graph."

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
