import CoreMedia
import Foundation

/// Platform-neutral receiver orchestration for macOS, iPhone, and iPad.
///
/// The UI supplies a short-lived token and receives selected sample buffers. This
/// object owns no camera or microphone capture graph; mobile sender capture remains
/// a separate composition concern.
@MainActor
public final class LinkReceiverSession {
    public private(set) var state: SessionState = .idle
    public private(set) var remoteTracks: [RemoteMediaTrack] = []
    public private(set) var selectedVideoTrack: MediaTrackSelectionID?
    public private(set) var selectedAudioTrack: MediaTrackSelectionID?

    public var onStateChanged: ((SessionState) -> Void)?
    public var onTracksChanged: (([RemoteMediaTrack]) -> Void)?
    public var onVideoFrame: ((MediaTrackID, CMSampleBuffer) -> Void)?
    public var onAudioFrame: ((MediaTrackID, CMSampleBuffer) -> Void)?

    private let session: MediaSession
    private var subscribedTrackIDs = Set<MediaTrackID>()

    public init(session: MediaSession = LiveKitMediaSession()) {
        self.session = session
        wireCallbacks()
    }

    public func connect(configuration: SessionConfiguration) async throws {
        guard state == .idle || isFailed else { return }
        subscribedTrackIDs.removeAll()
        setState(.connecting)
        do {
            try await session.connect(configuration: configuration)
            setState(session.state == .connecting ? .connected : session.state)
            receive(session.remoteTracks)
        } catch {
            setState(.failed(message: error.localizedDescription))
            throw error
        }
    }

    public func disconnect() async {
        await session.disconnect()
        subscribedTrackIDs.removeAll()
        remoteTracks = []
        selectedVideoTrack = nil
        selectedAudioTrack = nil
        onTracksChanged?([])
        setState(.idle)
    }

    /// Explicit source choice for operator UIs. Audio follows the same participant.
    public func selectVideoTrack(_ selection: MediaTrackSelectionID) {
        guard remoteTracks.contains(where: { $0.selectionID == selection && $0.kind == .camera }) else { return }
        selectedVideoTrack = selection
        selectMatchingAudio()
        subscribeIfNeeded(selection.trackID)
        subscribeIfNeeded(selectedAudioTrack?.trackID)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func wireCallbacks() {
        session.onStateChanged = { [weak self] value in
            Task { @MainActor in self?.setState(value) }
        }
        session.onRemoteTracksChanged = { [weak self] tracks in
            Task { @MainActor in self?.receive(tracks) }
        }
        session.onRemoteVideoFrame = { [weak self] trackID, sampleBuffer in
            Task { @MainActor in
                guard let self, self.selectedVideoTrack?.trackID == trackID else { return }
                self.onVideoFrame?(trackID, sampleBuffer)
            }
        }
        session.onRemoteAudio = { [weak self] trackID, sampleBuffer in
            Task { @MainActor in
                guard let self, self.selectedAudioTrack?.trackID == trackID else { return }
                self.onAudioFrame?(trackID, sampleBuffer)
            }
        }
    }

    private func receive(_ tracks: [RemoteMediaTrack]) {
        remoteTracks = tracks.sorted(by: Self.trackOrder)
        if let selectedVideoTrack,
           !remoteTracks.contains(where: { $0.selectionID == selectedVideoTrack && $0.kind == .camera }) {
            self.selectedVideoTrack = nil
        }
        if selectedVideoTrack == nil {
            selectedVideoTrack = remoteTracks.first(where: { $0.kind == .camera && !$0.isMuted })?.selectionID
        }
        selectMatchingAudio()
        subscribeIfNeeded(selectedVideoTrack?.trackID)
        subscribeIfNeeded(selectedAudioTrack?.trackID)
        onTracksChanged?(remoteTracks)
    }

    private func selectMatchingAudio() {
        guard let participantID = selectedVideoTrack?.participantID else {
            selectedAudioTrack = nil
            return
        }
        if let selectedAudioTrack,
           remoteTracks.contains(where: {
               $0.selectionID == selectedAudioTrack && $0.kind == .microphone && $0.participantID == participantID
           }) {
            return
        }
        selectedAudioTrack = remoteTracks.first(where: {
            $0.participantID == participantID && $0.kind == .microphone && !$0.isMuted
        })?.selectionID
    }

    private func subscribeIfNeeded(_ trackID: MediaTrackID?) {
        guard let trackID, !subscribedTrackIDs.contains(trackID) else { return }
        subscribedTrackIDs.insert(trackID)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.subscribe(to: trackID)
            } catch {
                self.subscribedTrackIDs.remove(trackID)
                self.setState(.failed(message: "Could not subscribe to remote media: \(error.localizedDescription)"))
            }
        }
    }

    private func setState(_ value: SessionState) {
        guard state != value else { return }
        state = value
        onStateChanged?(value)
    }

    private static func trackOrder(_ lhs: RemoteMediaTrack, _ rhs: RemoteMediaTrack) -> Bool {
        let name = lhs.participantName.localizedCaseInsensitiveCompare(rhs.participantName)
        if name != .orderedSame { return name == .orderedAscending }
        if lhs.participantID != rhs.participantID { return lhs.participantID.rawValue < rhs.participantID.rawValue }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}
