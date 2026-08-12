import AudioToolbox
import CoreMedia
import Foundation

/// Presents legacy NDI's one-source sender/receiver as a session with one stable,
/// synthetic participant and camera track.
final class NDIMediaSession: NSObject, MediaSession, VideoReceiverDelegate {
    enum Endpoint: Equatable {
        case publish(sourceName: String, clockVideo: Bool)
        case receive(sourceName: String, sourceAddress: String)
    }

    enum Error: Swift.Error, Equatable {
        case unsupportedOperation
        case senderUnavailable
        case receiverUnavailable
        case notConnected
        case unknownTrack
    }

    typealias SenderFactory = (_ sourceName: String, _ clockVideo: Bool) -> VideoSender?
    typealias ReceiverFactory = (_ sourceName: String, _ sourceAddress: String) -> VideoReceiver?

    private let endpoint: Endpoint
    private let makeSender: SenderFactory
    private let makeReceiver: ReceiverFactory
    private let mediaQueue = DispatchQueue(label: "StageGlassLink.NDIMediaSession.Media", qos: .userInteractive)
    private let lock = NSLock()
    private var storedState: SessionState = .idle
    private var storedRemoteTracks: [RemoteMediaTrack] = []
    private var sender: VideoSender?
    private var receiver: VideoReceiver?
    private var sourceSubscription: LocalMediaSource.Subscription?
    private var microphoneEnabled = false
    private var subscribedTrackID: MediaTrackID?
    private var syntheticAudioPTS = CMTime.zero

    var onStateChanged: ((SessionState) -> Void)?
    var onRemoteTracksChanged: (([RemoteMediaTrack]) -> Void)?
    var onRemoteVideoFrame: ((MediaTrackID, CMSampleBuffer) -> Void)?
    var onRemoteAudio: ((MediaTrackID, CMSampleBuffer) -> Void)?

    init(
        endpoint: Endpoint,
        makeSender: @escaping SenderFactory = { NDIVideoSender(sourceName: $0, clockVideo: $1) },
        makeReceiver: @escaping ReceiverFactory = { NDIVideoReceiver(sourceName: $0, sourceAddress: $1) }
    ) {
        self.endpoint = endpoint
        self.makeSender = makeSender
        self.makeReceiver = makeReceiver
        super.init()
    }

    var state: SessionState {
        lock.lock()
        defer { lock.unlock() }
        return storedState
    }

    var remoteTracks: [RemoteMediaTrack] {
        lock.lock()
        defer { lock.unlock() }
        return storedRemoteTracks
    }

    func connect(configuration: SessionConfiguration) async throws {
        transition(to: .connecting)
        switch endpoint {
        case let .publish(sourceName, clockVideo):
            guard let sender = makeSender(sourceName, clockVideo) else {
                transition(to: .failed(message: "NDI sender is unavailable."))
                throw Error.senderUnavailable
            }
            lock.lock()
            self.sender = sender
            lock.unlock()
        case let .receive(sourceName, sourceAddress):
            let track = Self.syntheticTrack(sourceName: sourceName, sourceAddress: sourceAddress)
            lock.lock()
            storedRemoteTracks = [track]
            lock.unlock()
            notifyTracksChanged([track])
        }
        transition(to: .connected)
    }

    func publishCamera(_ source: LocalMediaSource) async throws {
        guard case .publish = endpoint else { throw Error.unsupportedOperation }
        lock.lock()
        let connectedSender = sender
        lock.unlock()
        guard let connectedSender else { throw Error.notConnected }

        sourceSubscription?.cancel()
        sourceSubscription = source.subscribe(
            queue: mediaQueue,
            onVideoFrame: { [weak connectedSender] pixelBuffer, _ in
                connectedSender?.send(pixelBuffer: pixelBuffer, frameRateN: 30, frameRateD: 1)
            },
            onAudioSampleBuffer: { [weak self, weak connectedSender] sampleBuffer in
                guard let self, self.isMicrophoneEnabled else { return }
                connectedSender?.sendAudio(sampleBuffer)
            }
        )
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard case .publish = endpoint else { throw Error.unsupportedOperation }
        lock.lock()
        guard sender != nil else {
            lock.unlock()
            throw Error.notConnected
        }
        microphoneEnabled = enabled
        lock.unlock()
    }

    func subscribe(to trackID: MediaTrackID) async throws {
        guard case let .receive(sourceName, sourceAddress) = endpoint else {
            throw Error.unsupportedOperation
        }
        guard remoteTracks.contains(where: { $0.id == trackID }) else { throw Error.unknownTrack }

        lock.lock()
        if subscribedTrackID == trackID, receiver != nil {
            lock.unlock()
            return
        }
        let oldReceiver = receiver
        receiver = nil
        subscribedTrackID = nil
        lock.unlock()
        oldReceiver?.delegate = nil
        oldReceiver?.stop()

        guard let newReceiver = makeReceiver(sourceName, sourceAddress) else {
            transition(to: .failed(message: "NDI receiver is unavailable."))
            throw Error.receiverUnavailable
        }
        newReceiver.delegate = self
        lock.lock()
        receiver = newReceiver
        subscribedTrackID = trackID
        lock.unlock()
    }

    func disconnect() async {
        sourceSubscription?.cancel()
        sourceSubscription = nil

        lock.lock()
        let oldSender = sender
        let oldReceiver = receiver
        sender = nil
        receiver = nil
        subscribedTrackID = nil
        storedRemoteTracks = []
        microphoneEnabled = false
        lock.unlock()

        oldReceiver?.delegate = nil
        oldReceiver?.stop()
        oldSender?.stop()
        transition(to: .idle)
    }

    func currentStats() -> TransportStats? {
        lock.lock()
        defer { lock.unlock() }
        return sender?.currentStats() ?? receiver?.currentStats()
    }

    private var isMicrophoneEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return microphoneEnabled
    }

    private func transition(to state: SessionState) {
        lock.lock()
        storedState = state
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStateChanged?(state) }
    }

    private func notifyTracksChanged(_ tracks: [RemoteMediaTrack]) {
        DispatchQueue.main.async { [weak self] in self?.onRemoteTracksChanged?(tracks) }
    }

    private static func syntheticTrack(sourceName: String, sourceAddress: String) -> RemoteMediaTrack {
        let identity = sourceAddress.isEmpty ? sourceName : sourceAddress
        let participantID = ParticipantID(rawValue: "ndi-participant:\(identity)")
        return RemoteMediaTrack(
            id: MediaTrackID(rawValue: "ndi-camera:\(identity)"),
            participantID: participantID,
            participantName: sourceName,
            kind: .camera,
            isMuted: false
        )
    }

    // MARK: - VideoReceiverDelegate

    func videoReceiverDidReceive(
        sampleBuffer: CMSampleBuffer,
        width: Int32,
        height: Int32,
        frameRateN: Int32,
        frameRateD: Int32,
        fourCC: UInt32
    ) {
        guard let trackID = selectedTrackID else { return }
        DispatchQueue.main.async { [weak self] in self?.onRemoteVideoFrame?(trackID, sampleBuffer) }
    }

    func videoReceiverDidDisconnect() {
        transition(to: .failed(message: "NDI source disconnected."))
    }

    func videoReceiverDidStall(forSeconds seconds: Int) {
        transition(to: .reconnecting)
    }

    func videoReceiverDidResume() {
        transition(to: .connected)
    }

    func videoReceiverDidReceiveAudio(
        samples: UnsafePointer<Float>,
        sampleRate: Int32,
        channels: Int32,
        samplesPerChannel: Int32,
        channelStrideBytes: Int32
    ) {
        guard let trackID = selectedTrackID,
              let sampleBuffer = makeAudioSampleBuffer(
                samples: samples,
                sampleRate: sampleRate,
                channels: channels,
                samplesPerChannel: samplesPerChannel,
                channelStrideBytes: channelStrideBytes
              ) else { return }
        DispatchQueue.main.async { [weak self] in self?.onRemoteAudio?(trackID, sampleBuffer) }
    }

    private var selectedTrackID: MediaTrackID? {
        lock.lock()
        defer { lock.unlock() }
        return subscribedTrackID
    }

    private func makeAudioSampleBuffer(
        samples: UnsafePointer<Float>,
        sampleRate: Int32,
        channels: Int32,
        samplesPerChannel: Int32,
        channelStrideBytes: Int32
    ) -> CMSampleBuffer? {
        guard sampleRate > 0, channels > 0, samplesPerChannel > 0 else { return nil }
        let channelCount = Int(channels)
        let frameCount = Int(samplesPerChannel)
        let stride = Int(channelStrideBytes) / MemoryLayout<Float>.stride
        guard stride >= frameCount else { return nil }
        var interleaved = [Float](repeating: 0, count: channelCount * frameCount)
        for channel in 0..<channelCount {
            let source = samples.advanced(by: channel * stride)
            for frame in 0..<frameCount {
                interleaved[frame * channelCount + channel] = source[frame]
            }
        }
        lock.lock()
        let pts = syntheticAudioPTS
        syntheticAudioPTS = CMTimeAdd(
            syntheticAudioPTS,
            CMTime(value: CMTimeValue(frameCount), timescale: sampleRate)
        )
        lock.unlock()
        return AudioSampleBufferFactory.makeInterleavedFloat(
            samples: interleaved,
            sampleRate: sampleRate,
            channels: channels,
            presentationTime: pts
        )
    }
}
