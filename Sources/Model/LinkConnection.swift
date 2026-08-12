import Combine
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

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "Enter a valid secure Link server URL."
        case .missingRoom: return "Enter a room name."
        case .missingDisplayName: return "Enter a display name."
        case .missingAccessToken: return "Paste a short-lived access token."
        case .sessionUnavailable: return "Link is not available in this build."
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
        return SessionConfiguration(serverURL: url, roomName: room, displayName: name, accessToken: token)
    }
}

@MainActor
final class LinkConnectionController: ObservableObject {
    @Published var serverURL: String
    @Published var roomName: String
    @Published var displayName: String
    @Published var accessToken = ""
    @Published private(set) var state: SessionState = .idle

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
        guard session == nil else { return }
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
            created.onStateChanged = { [weak self] newState in
                Task { @MainActor in self?.state = newState }
            }
            state = .connecting
            try await created.connect(configuration: configuration)
            // Some adapters report state through the callback; normalize adapters that
            // complete connect before dispatching their notification.
            state = created.state == .connecting ? .connected : created.state
        } catch {
            session = nil
            state = .failed(message: error.localizedDescription)
        }
    }

    func leave() async {
        let current = session
        session = nil
        await current?.disconnect()
        accessToken = ""
        state = .idle
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
}
