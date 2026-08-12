import CoreMedia
import CoreVideo
import Foundation

/// Product-facing release modes. Experimental transports intentionally never enter this type.
enum LinkMode: String, CaseIterable, Codable {
    case link
    case ndi

    static let releaseCapabilities: [LinkMode] = [.link, .ndi]

    var displayName: String {
        switch self {
        case .link: return "Link"
        case .ndi: return "NDI"
        }
    }

    /// Reads the new key first, then the legacy transport key for one migration release.
    /// QuicLink, WarpStream, unknown values, and a missing preference all settle on Link.
    static func restored(from defaults: UserDefaults,
                         key: String,
                         legacyKey: String) -> LinkMode {
        if let raw = defaults.string(forKey: key), let mode = LinkMode(rawValue: raw) {
            return mode
        }
        if defaults.string(forKey: legacyKey) == VideoTransportKind.ndi.rawValue {
            return .ndi
        }
        return .link
    }
}

/// Legacy/internal transport identity retained while experimental source is archived.
enum VideoTransportKind: String, CaseIterable {
    case ndi
    case quicLink
    case warpStream
}

/// A discovered source the receiver can connect to, tagged by transport.
struct FoundSource: Equatable {
    let name: String
    let address: String
    let transport: VideoTransportKind
    /// QuicLink + WarpStream (Bonjour path): the UDP port the sender advertises. nil for NDI and for room-code paths.
    var port: UInt16? = nil
    /// QuicLink: SHA-256 of the sender's leaf cert DER. WarpStream: PSK fingerprint. nil for NDI and for room-code paths.
    var pinSHA256: Data? = nil
    /// WarpStream only: the room code identifying the session. Surfaced from Bonjour TXT or entered manually by the operator.
    var roomCode: String? = nil
}

/// Sends camera frames + audio over some transport. Mirrors the NDISender surface.
protocol VideoSender: AnyObject {
    func send(pixelBuffer: CVPixelBuffer, frameRateN: Int32, frameRateD: Int32)
    func repeatLastFrame(frameRateN: Int32, frameRateD: Int32)
    func sendAudio(_ sampleBuffer: CMSampleBuffer)
    func stop()
    /// Optional shootout instrumentation. Default impl returns nil so existing
    /// transports compile without changes.
    func currentStats() -> TransportStats?
}

extension VideoSender {
    func currentStats() -> TransportStats? { nil }
}

/// Receives decoded frames + audio. Callbacks fire on a non-main (transport) thread;
/// the implementer is responsible for hopping to the main actor as needed.
protocol VideoReceiverDelegate: AnyObject {
    func videoReceiverDidReceive(sampleBuffer: CMSampleBuffer, width: Int32, height: Int32,
                                 frameRateN: Int32, frameRateD: Int32, fourCC: UInt32)
    func videoReceiverDidDisconnect()
    func videoReceiverDidStall(forSeconds seconds: Int)
    func videoReceiverDidResume()
    func videoReceiverDidReceiveAudio(samples: UnsafePointer<Float>, sampleRate: Int32,
                                      channels: Int32, samplesPerChannel: Int32,
                                      channelStrideBytes: Int32)
}

protocol VideoReceiver: AnyObject {
    var delegate: VideoReceiverDelegate? { get set }
    func stop()
    /// Optional shootout instrumentation. Default impl returns nil so existing
    /// transports compile without changes.
    func currentStats() -> TransportStats?
}

extension VideoReceiver {
    func currentStats() -> TransportStats? { nil }
}

/// Discovers sources on the network for one transport.
protocol SourceFinder: AnyObject {
    var onSourcesChanged: (([FoundSource]) -> Void)? { get set }
    func currentSources() -> [FoundSource]
    func stop()
}
