import CoreMedia
import CoreVideo
import Foundation

/// Wraps the ObjC NDISender behind the VideoSender protocol.
final class NDIVideoSender: VideoSender {
    private let ndi: NDISender

    init?(sourceName: String, clockVideo: Bool) {
        guard let ndi = NDISender(sourceName: sourceName, clockVideo: clockVideo) else { return nil }
        self.ndi = ndi
    }

    func send(pixelBuffer: CVPixelBuffer, frameRateN: Int32, frameRateD: Int32) {
        ndi.send(pixelBuffer, frameRateN: frameRateN, frameRateD: frameRateD)
    }

    func repeatLastFrame(frameRateN: Int32, frameRateD: Int32) {
        ndi.repeatLastFrame(withFrameRateN: frameRateN, frameRateD: frameRateD)
    }

    func sendAudio(_ sampleBuffer: CMSampleBuffer) { ndi.sendAudio(sampleBuffer) }

    func stop() { ndi.stop() }

    // NDI SDK does not expose per-stream metrics; adapter has no meter yet.
    // Returning nil makes the stats overlay render "—" for the NDI baseline.
    func currentStats() -> TransportStats? { nil }
}

/// Wraps the ObjC NDIReceiver, translating its delegate callbacks to VideoReceiverDelegate.
final class NDIVideoReceiver: NSObject, VideoReceiver, NDIReceiverDelegate {
    weak var delegate: VideoReceiverDelegate?
    private let ndi: NDIReceiver

    init?(sourceName: String, sourceAddress: String) {
        guard let ndi = NDIReceiver(sourceName: sourceName, sourceAddress: sourceAddress) else { return nil }
        self.ndi = ndi
        super.init()
        ndi.delegate = self
    }

    func stop() {
        ndi.delegate = nil
        ndi.stop()
    }

    func currentStats() -> TransportStats? { nil }

    // MARK: NDIReceiverDelegate → VideoReceiverDelegate

    func receiverDidReceive(_ sampleBuffer: CMSampleBuffer, width: Int32, height: Int32,
                            frameRateN: Int32, frameRateD: Int32, fourCC: UInt32) {
        delegate?.videoReceiverDidReceive(sampleBuffer: sampleBuffer, width: width, height: height,
                                          frameRateN: frameRateN, frameRateD: frameRateD, fourCC: fourCC)
    }

    func receiverDidDisconnect() { delegate?.videoReceiverDidDisconnect() }

    func receiverDidStall(forSeconds seconds: Int) { delegate?.videoReceiverDidStall(forSeconds: seconds) }

    func receiverDidResume() { delegate?.videoReceiverDidResume() }

    func receiverDidReceiveAudio(_ samples: UnsafePointer<Float>, sampleRate: Int32, channels: Int32,
                                 samplesPerChannel: Int32, channelStrideBytes: Int32) {
        delegate?.videoReceiverDidReceiveAudio(samples: samples, sampleRate: sampleRate, channels: channels,
                                               samplesPerChannel: samplesPerChannel,
                                               channelStrideBytes: channelStrideBytes)
    }
}

/// Wraps NDIFinder, mapping NDIFoundSource → FoundSource tagged `.ndi`.
final class NDISourceFinder: SourceFinder {
    var onSourcesChanged: (([FoundSource]) -> Void)?
    private let finder: NDIFinder?

    init() {
        finder = NDIFinder.startNew()
        finder?.onSourcesChanged = { [weak self] sources in
            self?.onSourcesChanged?(sources.map { Self.map($0.name, $0.address) })
        }
    }

    func currentSources() -> [FoundSource] {
        (finder?.currentSources() ?? []).map { Self.map($0.name, $0.address) }
    }

    func stop() { finder?.stop() }

    static func map(_ name: String, _ address: String) -> FoundSource {
        FoundSource(name: name, address: address, transport: .ndi)
    }

    /// Test seam for the pure mapping (avoids needing a live NDI runtime in unit tests).
    static func mapForTesting(name: String, address: String) -> FoundSource {
        map(name, address)
    }
}

/// Release factory. Experimental transports cannot be selected or instantiated here.
enum TransportFactory {
    static func makeSender(mode: LinkMode, sourceName: String,
                           clockVideo: Bool) -> VideoSender? {
        switch mode {
        case .ndi: return NDIVideoSender(sourceName: sourceName, clockVideo: clockVideo)
        case .link: return nil // LiveKit adapter lands in Phase 2.
        }
    }

    static func makeReceiver(for source: FoundSource) -> VideoReceiver? {
        guard source.transport == .ndi else { return nil }
        return NDIVideoReceiver(sourceName: source.name, sourceAddress: source.address)
    }

    /// NDI is the only release mode with LAN discovery.
    static func makeFinders() -> [SourceFinder] {
        [NDISourceFinder()]
    }
}
