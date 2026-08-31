import Combine
import CoreMedia
import Foundation

/// Construction seam owned by the app composition root. Models never import a
/// concrete WebRTC SDK and tests can supply a deterministic session.
typealias LinkMediaSessionFactory = @MainActor () -> MediaSession

enum LinkConnectionInputError: LocalizedError, Equatable {
    case invalidServerURL
    case missingRoom
    case missingDisplayName
    case missingAccessToken
    case sessionUnavailable
    case expectedRoomMismatch(expected: String, token: String)
    case expectedIdentityMismatch(expected: String, token: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "Enter a valid secure Link server URL."
        case .missingRoom: return "Enter a room name."
        case .missingDisplayName: return "Enter a display name."
        case .missingAccessToken: return "Paste a short-lived access token."
        case .sessionUnavailable: return "Link is not available in this build."
        case .expectedRoomMismatch(let expected, let token):
            return "Expected room ‘\(expected)’ does not match token room ‘\(token)’."
        case .expectedIdentityMismatch(let expected, let token):
            return "Expected identity ‘\(expected)’ does not match token identity ‘\(token)’."
        }
    }
}

enum LinkConnectionRuntimeError: LocalizedError, Equatable {
    case cameraRequiresJoinedSession
    case microphoneRequiresJoinedSession

    var errorDescription: String? {
        switch self {
        case .cameraRequiresJoinedSession:
            return "Join a Link session before starting the camera."
        case .microphoneRequiresJoinedSession:
            return "Join a Link session before changing the microphone."
        }
    }
}

struct LinkConnectionFields: Equatable {
    var serverURL: String
    var roomName: String
    var displayName: String
    /// Runtime-only secret. This value must never be written to UserDefaults or logs.
    var accessToken: String

    func configuration() throws -> SessionConfiguration {
        let server = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: server),
              let scheme = url.scheme?.lowercased(),
              scheme == "wss" || scheme == "https",
              url.host != nil else {
            throw LinkConnectionInputError.invalidServerURL
        }
        let room = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !room.isEmpty else { throw LinkConnectionInputError.missingRoom }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LinkConnectionInputError.missingDisplayName }
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw LinkConnectionInputError.missingAccessToken }
        if let claims = LinkTokenClaims(token: token) {
            if let tokenRoom = claims.room, tokenRoom != room {
                throw LinkConnectionInputError.expectedRoomMismatch(expected: room, token: tokenRoom)
            }
            if let tokenIdentity = claims.identity, tokenIdentity != name {
                throw LinkConnectionInputError.expectedIdentityMismatch(expected: name, token: tokenIdentity)
            }
            return SessionConfiguration(serverURL: url,
                                        roomName: claims.room ?? room,
                                        displayName: claims.displayName ?? claims.identity ?? name,
                                        accessToken: token)
        }
        return SessionConfiguration(serverURL: url, roomName: room, displayName: name, accessToken: token)
    }
}

/// Non-verifying JWT claim inspection used only to prevent the operator UI from
/// promising a room/identity different from the signed token. LiveKit remains
/// responsible for signature and authorization validation at connection time.
private struct LinkTokenClaims {
    let identity: String?
    let displayName: String?
    let room: String?

    init?(token: String) {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        var encoded = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        identity = object["sub"] as? String
        displayName = object["name"] as? String
        room = (object["video"] as? [String: Any])?["room"] as? String
    }
}

@MainActor
final class LinkConnectionController: ObservableObject {
    @Published var serverURL: String
    @Published var roomName: String
    @Published var displayName: String
    @Published var accessToken = ""
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var remoteTracks: [RemoteMediaTrack] = []
    @Published private(set) var selectedVideoTrack: MediaTrackSelectionID?
    @Published private(set) var selectedAudioTrack: MediaTrackSelectionID?

    var onRemoteVideoFrame: ((MediaTrackID, CMSampleBuffer) -> Void)?
    var onRemoteAudio: ((MediaTrackID, CMSampleBuffer) -> Void)?
    var onSessionStateChanged: ((SessionState) -> Void)?

    private let makeSession: LinkMediaSessionFactory?
    private var session: MediaSession?

    init(defaults: UserDefaults = .standard,
         keyPrefix: String,
         defaultDisplayName: String,
         makeSession: LinkMediaSessionFactory?) {
        self.serverURL = defaults.string(forKey: "\(keyPrefix)LinkServerURL") ?? ""
        self.roomName = defaults.string(forKey: "\(keyPrefix)LinkRoom") ?? ""
        self.displayName = defaults.string(forKey: "\(keyPrefix)LinkDisplayName") ?? defaultDisplayName
        self.makeSession = makeSession
    }

    var isJoined: Bool { state == .connected || state == .reconnecting }
    var isBusy: Bool { state == .connecting }

    func saveNonSecretFields(to defaults: UserDefaults = .standard, keyPrefix: String) {
        defaults.set(serverURL, forKey: "\(keyPrefix)LinkServerURL")
        defaults.set(roomName, forKey: "\(keyPrefix)LinkRoom")
        defaults.set(displayName, forKey: "\(keyPrefix)LinkDisplayName")
    }

    func join() async {
        if let previous = session {
            switch state {
            case .failed, .idle:
                session = nil
                await previous.disconnect()
            case .connecting, .connected, .reconnecting:
                return
            }
        }
        do {
            let configuration = try LinkConnectionFields(
                serverURL: serverURL,
                roomName: roomName,
                displayName: displayName,
                accessToken: accessToken
            ).configuration()
            guard let makeSession else { throw LinkConnectionInputError.sessionUnavailable }
            let created = makeSession()
            session = created
            subscribedTrackIDs.removeAll()
            created.onStateChanged = { [weak self, weak created] newState in
                Task { @MainActor in
                    guard let self, let created, self.session === created else { return }
                    self.setState(newState)
                }
            }
            created.onRemoteTracksChanged = { [weak self, weak created] tracks in
                Task { @MainActor in
                    guard let self, let created, self.session === created else { return }
                    self.receive(tracks: tracks)
                }
            }
            created.onRemoteVideoFrame = { [weak self, weak created] trackID, sampleBuffer in
                Task { @MainActor in
                    guard let self, let created, self.session === created else { return }
                    self.receiveVideo(trackID: trackID, sampleBuffer: sampleBuffer)
                }
            }
            created.onRemoteAudio = { [weak self, weak created] trackID, sampleBuffer in
                Task { @MainActor in
                    guard let self, let created, self.session === created else { return }
                    self.receiveAudio(trackID: trackID, sampleBuffer: sampleBuffer)
                }
            }
            setState(.connecting)
            try await created.connect(configuration: configuration)
            // Some adapters report state through the callback; normalize adapters that
            // complete connect before dispatching their notification.
            setState(created.state == .connecting ? .connected : created.state)
            receive(tracks: created.remoteTracks)
        } catch {
            let failed = session
            session = nil
            await failed?.disconnect()
            setState(.failed(message: error.localizedDescription))
        }
    }

    func leave() async {
        let current = session
        session = nil
        await current?.disconnect()
        accessToken = ""
        remoteTracks = []
        selectedVideoTrack = nil
        selectedAudioTrack = nil
        subscribedTrackIDs.removeAll()
        setState(.idle)
    }

    /// Publishes application-owned camera frames without exposing the underlying
    /// session (or any LiveKit type) to the broadcast model.
    func publishCamera(_ source: LocalMediaSource) async throws {
        guard isJoined, let session else {
            throw LinkConnectionRuntimeError.cameraRequiresJoinedSession
        }
        try await session.publishCamera(source)
    }

    /// Applies the Link microphone policy. The LiveKit adapter owns network mic
    /// capture; CameraManager remains available independently for local recording.
    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard isJoined, let session else {
            throw LinkConnectionRuntimeError.microphoneRequiresJoinedSession
        }
        try await session.setMicrophoneEnabled(enabled)
    }

    var statusText: String {
        switch state {
        case .idle: return "Not joined"
        case .connecting: return "Joining…"
        case .connected: return "Joined"
        case .reconnecting: return "Reconnecting…"
        case .failed(let message): return message
        }
    }

    private func setState(_ newState: SessionState) {
        state = newState
        onSessionStateChanged?(newState)
    }

    private func receive(tracks: [RemoteMediaTrack]) {
        remoteTracks = tracks.sorted(by: Self.trackOrder)

        if let selectedVideoTrack,
           !tracks.contains(where: {
               $0.selectionID == selectedVideoTrack && $0.kind == .camera && !$0.isMuted
           }) {
            self.selectedVideoTrack = nil
        }
        if self.selectedVideoTrack == nil {
            self.selectedVideoTrack = remoteTracks.first(where: { $0.kind == .camera && !$0.isMuted })?.selectionID
        }

        let selectedParticipant = selectedVideoTrack?.participantID
        if let selectedAudioTrack,
           (!tracks.contains(where: {
               $0.selectionID == selectedAudioTrack && $0.kind == .microphone && !$0.isMuted
           })
            || selectedAudioTrack.participantID != selectedParticipant) {
            self.selectedAudioTrack = nil
        }
        if self.selectedAudioTrack == nil, let selectedParticipant {
            self.selectedAudioTrack = remoteTracks.first(where: {
                $0.participantID == selectedParticipant && $0.kind == .microphone && !$0.isMuted
            })?.selectionID
        }

        subscribeIfNeeded(to: selectedVideoTrack?.trackID)
        subscribeIfNeeded(to: selectedAudioTrack?.trackID)
    }

    private var subscribedTrackIDs = Set<MediaTrackID>()

    private func subscribeIfNeeded(to trackID: MediaTrackID?) {
        guard let trackID, !subscribedTrackIDs.contains(trackID), let session else { return }
        subscribedTrackIDs.insert(trackID)
        Task { [weak self] in
            do {
                try await session.subscribe(to: trackID)
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.subscribedTrackIDs.remove(trackID)
                    self.setState(.failed(message: "Could not subscribe to remote media: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func receiveVideo(trackID: MediaTrackID, sampleBuffer: CMSampleBuffer) {
        guard selectedVideoTrack?.trackID == trackID else { return }
        onRemoteVideoFrame?(trackID, sampleBuffer)
    }

    private func receiveAudio(trackID: MediaTrackID, sampleBuffer: CMSampleBuffer) {
        guard selectedAudioTrack?.trackID == trackID else { return }
        onRemoteAudio?(trackID, sampleBuffer)
    }

    private static func trackOrder(_ lhs: RemoteMediaTrack, _ rhs: RemoteMediaTrack) -> Bool {
        let nameOrder = lhs.participantName.localizedCaseInsensitiveCompare(rhs.participantName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.participantID != rhs.participantID { return lhs.participantID.rawValue < rhs.participantID.rawValue }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}
