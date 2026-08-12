import CoreMedia
import CoreVideo
import Foundation

/// Product-facing transports. SDK-specific transports must not leak into this list.
enum LinkMode: String, CaseIterable, Codable {
    case link
    case ndi
}

/// Connection input shared by all media-session adapters.
///
/// `accessToken` intentionally participates in neither Codable nor description so a
/// caller cannot accidentally persist or log it with the rest of the configuration.
struct SessionConfiguration: Equatable, Codable, CustomStringConvertible {
    let serverURL: URL?
    let roomName: String?
    let displayName: String
    let accessToken: String?

    init(serverURL: URL?, roomName: String?, displayName: String, accessToken: String?) {
        self.serverURL = serverURL
        self.roomName = roomName
        self.displayName = displayName
        self.accessToken = accessToken
    }

    static func ndi(displayName: String) -> SessionConfiguration {
        SessionConfiguration(serverURL: nil, roomName: nil, displayName: displayName, accessToken: nil)
    }

    private enum CodingKeys: String, CodingKey {
        case serverURL
        case roomName
        case displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try container.decodeIfPresent(URL.self, forKey: .serverURL)
        roomName = try container.decodeIfPresent(String.self, forKey: .roomName)
        displayName = try container.decode(String.self, forKey: .displayName)
        accessToken = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(serverURL, forKey: .serverURL)
        try container.encodeIfPresent(roomName, forKey: .roomName)
        try container.encode(displayName, forKey: .displayName)
    }

    var description: String {
        let server = serverURL?.absoluteString ?? "nil"
        let room = roomName ?? "nil"
        return "SessionConfiguration(serverURL: \(server), roomName: \(room), displayName: \(displayName), accessToken: <redacted>)"
    }
}

struct ParticipantID: Hashable, Codable {
    let rawValue: String
}

struct MediaTrackID: Hashable, Codable {
    let rawValue: String
}

struct MediaTrackSelectionID: Hashable {
    let participantID: ParticipantID
    let trackID: MediaTrackID
}

enum MediaTrackKind: String, Codable {
    case camera
    case microphone
    case screenShare
    case unknown
}

struct RemoteMediaTrack: Identifiable, Equatable {
    let id: MediaTrackID
    let participantID: ParticipantID
    let participantName: String
    let kind: MediaTrackKind
    let isMuted: Bool

    var selectionID: MediaTrackSelectionID {
        MediaTrackSelectionID(participantID: participantID, trackID: id)
    }
}

enum SessionState: Equatable {
    case idle
    case connecting
    case connected
    case reconnecting
    case failed(message: String)
}

protocol MediaSession: AnyObject {
    var state: SessionState { get }
    var remoteTracks: [RemoteMediaTrack] { get }
    var onStateChanged: ((SessionState) -> Void)? { get set }
    var onRemoteTracksChanged: (([RemoteMediaTrack]) -> Void)? { get set }
    var onRemoteVideoFrame: ((MediaTrackID, CMSampleBuffer) -> Void)? { get set }
    var onRemoteAudio: ((MediaTrackID, CMSampleBuffer) -> Void)? { get set }

    func connect(configuration: SessionConfiguration) async throws
    func publishCamera(_ source: LocalMediaSource) async throws
    func setMicrophoneEnabled(_ enabled: Bool) async throws
    func subscribe(to trackID: MediaTrackID) async throws
    func disconnect() async
    func currentStats() -> TransportStats?
}
