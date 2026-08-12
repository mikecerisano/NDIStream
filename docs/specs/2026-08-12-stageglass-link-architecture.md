# StageGlass Link — Product and Architecture Specification

**Status:** approved direction; implementation not started  
**Date:** 2026-08-12  
**Supersedes:** the QuicLink and WarpStream product directions. Their documents remain historical references, not release plans.

## Product decision

Rename the product toward **StageGlass Link**: a small sender/receiver utility for live camera, microphone, monitoring, and recording. Preserve the current focused two-window workflow rather than redesigning the app.

The release transport choices are:

1. **Link (WebRTC)** — primary and selected by default, implemented with LiveKit.
2. **NDI** — retained for macOS interoperability with OBS, vMix, Resolume, TouchDesigner, and existing set hardware.

QuicLink and WarpStream are unfinished experiments. They must not appear in release UI, discovery, defaults, onboarding, or release claims. Their source may remain temporarily behind a non-release experimental flag so useful protocol and jitter-buffer work is not destroyed. No new product work should target either transport.

Platform order is Mac-to-Mac first, followed by Apple mobile, then Android. NDI is macOS-only unless a later product decision explicitly expands it.

## Operator experience

Keep the existing Sender and Receiver windows and their camera, microphone, slate, record, lock, statistics, and borderless-fullscreen behavior.

### Sender

- Default mode is **Link**.
- Link fields: server, room, display name, and a Join/Leave action. A production StageGlass launch may preconfigure these and hide server details.
- Once joined, Start Broadcasting publishes the selected camera and optional microphone.
- NDI mode keeps the existing source-name and broadcast behavior.
- Local preview and Sender recording consume the same captured media regardless of transport.

### Receiver

- Default mode is **Link**.
- Link fields match Sender. After joining, show remote participants and their available video tracks; automatically select the first playable remote camera track only when no prior valid selection exists.
- NDI mode keeps LAN discovery and the current source picker.
- Display, audio playback, Receiver recording, reconnect status, statistics, and fullscreen are transport-independent.

Do not expose the words LiveKit, QuicLink, or WarpStream in normal operator UI. “Link” is the product-facing transport name; LiveKit is an implementation detail.

## Architecture

The current `VideoSender`, `VideoReceiver`, and `SourceFinder` seam models a one-source frame transport. WebRTC is participant-, session-, and track-oriented. Add a session layer above transport adapters instead of forcing LiveKit rooms into `FoundSource`.

### Core domain types

These types must live in an SDK-independent `Sources/Session/` module. Do not import LiveKit in this module.

```swift
enum LinkMode: String, CaseIterable { case link, ndi }

struct SessionConfiguration: Equatable {
    let serverURL: URL?
    let roomName: String?
    let displayName: String
    let accessToken: String?
}

struct ParticipantID: Hashable { let rawValue: String }
struct MediaTrackID: Hashable { let rawValue: String }
enum MediaTrackKind { case camera, microphone, screenShare, unknown }

struct RemoteMediaTrack: Identifiable, Equatable {
    let id: MediaTrackID
    let participantID: ParticipantID
    let participantName: String
    let kind: MediaTrackKind
    let isMuted: Bool
}

enum SessionState: Equatable {
    case idle, connecting, connected, reconnecting
    case failed(message: String)
}
```

`accessToken` is an input secret, not persisted application state. Logs must never include it.

### Session contracts

```swift
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
```

`LocalMediaSource` is a small application-owned source that emits timestamped `CVPixelBuffer` video and `CMSampleBuffer` audio. It must not expose LiveKit types. Callbacks entering UI/controller state must hop to `MainActor`; capture and rendering must remain off the main thread.

Implementations:

- `LiveKitMediaSession`: owns one LiveKit room, maps participants/tracks to the domain types, publishes the existing camera/mic capture, converts subscribed frames to the existing display/recorder input, and surfaces reconnect/error/statistics state.
- `NDIMediaSession`: adapts the current NDI sender, finder, and receiver into a synthetic one-participant/one-track session. It accepts no server, room, or token.
- `MediaSessionFactory`: returns only Link and NDI in release builds. Experimental transports, if retained, use a separate `#if INTERNAL_EXPERIMENTS` factory and never enter `LinkMode.allCases`.

The existing `VideoSender`/`VideoReceiver` protocols can remain as private NDI adapter details during migration. They are no longer the product-level model.

### Shared media pipeline

Preserve and reuse `CameraManager`, `PreviewView`, `DisplayLayerHostView`, `AudioPlayer`, and `Recorder`.

```text
CameraManager ──> LocalMediaSource ──┬──> local preview
                                    ├──> Sender Recorder
                                    └──> active MediaSession publisher

active MediaSession subscriber ─────┬──> DisplayLayerHostView
                                    ├──> AudioPlayer
                                    └──> Receiver Recorder
```

One capture session feeds preview, recording, and publishing; a transport must not open a second camera or microphone. Preserve source timestamps through every branch. Apply bounded buffering and drop video frames under backpressure; never block the capture callback. Audio discontinuities should surface as errors or metrics rather than silently accumulating latency.

### LiveKit connection contract

LiveKit requires a WebSocket server URL and a short-lived participant token. It does not provide NDI-style LAN discovery.

- Developer/Mac-to-Mac milestone: allow manually supplied server URL, room name, display name, and token in an Advanced connection sheet or launch configuration.
- Production StageGlass flow: StageGlass creates/chooses the room and obtains least-privilege, short-lived publish/subscribe tokens from a trusted token service. It launches Link with a versioned deep link or configuration payload.
- Never mint production LiveKit API-secret tokens in the client.
- Persist server URL, display name, and last room only when appropriate; never persist access tokens.
- A participant may publish multiple tracks. Selection identity is `(participantID, trackID)`, never display name.

Proposed integration payload (version 1):

```json
{
  "version": 1,
  "serverURL": "wss://…",
  "roomName": "…",
  "displayName": "Camera A",
  "role": "publish|subscribe|both",
  "token": "short-lived-token"
}
```

Transport this payload through an authenticated StageGlass handoff. A URL scheme may carry an opaque one-time handoff code, but must not put the token directly into URLs, shell arguments, analytics, or logs.

## Compatibility and migration

| Capability | Link on macOS | NDI on macOS | Apple mobile (later) | Android (later) |
|---|---:|---:|---:|---:|
| Camera publish | Yes | Yes | Yes | Yes |
| Microphone publish | Yes | Yes | Yes | Yes |
| Video/audio receive | Yes | Yes | Yes | Yes |
| Local recording | Yes | Yes | Yes | Yes, after Android recorder work |
| LAN source discovery | No; room join | Yes | No | No |
| Third-party NDI tools | No | Yes | No | No |

On first launch after migration, map saved `.quicLink` or `.warpStream` preferences to `.link`; preserve `.ndi`. Keep old preference keys readable for one release, then write only the new `LinkMode` key. Rename bundle/repository identifiers only in a dedicated release task so recordings, preferences, signing, updates, and release automation can be migrated deliberately.

## Quality gates

Mac-to-Mac Link is releasable only when all of the following hold:

- Two Macs can join the same room, publish camera/mic, select a remote track, and receive synchronized video/audio.
- Sender and Receiver recordings open and contain the expected video and audio tracks.
- Camera or microphone changes do not create duplicate capture sessions or leak old tracks.
- Remote mute, unpublish, participant leave/rejoin, network interruption, and app stop all settle into a truthful UI state.
- A 30-minute call has bounded memory and no steadily increasing A/V latency.
- Link is the default; NDI remains functional; QuicLink/WarpStream are absent from release UI and cannot be instantiated by release factory paths.
- Tokens are absent from UserDefaults and logs.

## Explicit non-goals for the first release

- Embedded LiveKit server, mesh/P2P transport, WAN account system, screen sharing, simulcast controls, multi-view, effects/compositing, or QuicLink/WarpStream completion.
- Full StageGlass control-plane integration before Mac-to-Mac media reliability is proven.
- Mobile NDI support.
