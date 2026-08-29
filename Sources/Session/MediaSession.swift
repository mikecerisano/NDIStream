import CoreMedia
import CoreVideo
import Foundation

/// Connection input shared by all media-session adapters.
///
/// `accessToken` intentionally participates in neither Codable nor description so a
/// caller cannot accidentally persist or log it with the rest of the configuration.
public struct SessionConfiguration: Equatable, Codable, CustomStringConvertible {
    public let serverURL: URL?
    public let roomName: String?
    public let displayName: String
    public let accessToken: String?

    public init(serverURL: URL?, roomName: String?, displayName: String, accessToken: String?) {
        self.serverURL = serverURL
        self.roomName = roomName
        self.displayName = displayName
        self.accessToken = accessToken
    }

    public static func ndi(displayName: String) -> SessionConfiguration {
        SessionConfiguration(serverURL: nil, roomName: nil, displayName: displayName, accessToken: nil)
    }

    private enum CodingKeys: String, CodingKey {
        case serverURL
        case roomName
        case displayName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try container.decodeIfPresent(URL.self, forKey: .serverURL)
        roomName = try container.decodeIfPresent(String.self, forKey: .roomName)
        displayName = try container.decode(String.self, forKey: .displayName)
        accessToken = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(serverURL, forKey: .serverURL)
        try container.encodeIfPresent(roomName, forKey: .roomName)
        try container.encode(displayName, forKey: .displayName)
    }

    public var description: String {
        let server = serverURL?.absoluteString ?? "nil"
        let room = roomName ?? "nil"
        return "SessionConfiguration(serverURL: \(server), roomName: \(room), displayName: \(displayName), accessToken: <redacted>)"
    }
}

public struct ParticipantID: Hashable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct MediaTrackID: Hashable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct MediaTrackSelectionID: Hashable {
    public let participantID: ParticipantID
    public let trackID: MediaTrackID
    public init(participantID: ParticipantID, trackID: MediaTrackID) {
        self.participantID = participantID
        self.trackID = trackID
    }
}

public enum MediaTrackKind: String, Codable {
    case camera
    case microphone
    case screenShare
    case unknown
}

public struct RemoteMediaTrack: Identifiable, Equatable {
    public let id: MediaTrackID
    public let participantID: ParticipantID
    public let participantName: String
    public let kind: MediaTrackKind
    public let isMuted: Bool

    public init(id: MediaTrackID, participantID: ParticipantID, participantName: String, kind: MediaTrackKind, isMuted: Bool) {
        self.id = id
        self.participantID = participantID
        self.participantName = participantName
        self.kind = kind
        self.isMuted = isMuted
    }

    public var selectionID: MediaTrackSelectionID {
        MediaTrackSelectionID(participantID: participantID, trackID: id)
    }
}

public enum SessionState: Equatable {
    case idle
    case connecting
    case connected
    case reconnecting
    case failed(message: String)
}

public protocol MediaSession: AnyObject {
    var state: SessionState { get }
    var remoteTracks: [RemoteMediaTrack] { get }
    var onStateChanged: ((SessionState) -> Void)? { get set }
    var onRemoteTracksChanged: (([RemoteMediaTrack]) -> Void)? { get set }
    var onRemoteVideoFrame: ((MediaTrackID, CMSampleBuffer) -> Void)? { get set }
    var onRemoteAudio: ((MediaTrackID, CMSampleBuffer) -> Void)? { get set }

    func connect(configuration: SessionConfiguration) async throws
    func publishCamera(_ source: LocalMediaSource) async throws
    func setMicrophoneEnabled(_ enabled: Bool) async throws
    func setCameraPublishEnabled(_ enabled: Bool) async throws
    /// Operator mute for REMOTE audio playback (peer voice). Default no-op.
    func setRemotePlaybackMuted(_ muted: Bool)
    func subscribe(to trackID: MediaTrackID) async throws
    func disconnect() async
    func currentStats() -> TransportStats?
}


public extension MediaSession {
    /// Sessions without SDK playout (NDI) have nothing to mute remotely.
    func setRemotePlaybackMuted(_ muted: Bool) {}
}
