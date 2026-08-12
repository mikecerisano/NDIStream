# StageGlass Link — Phased Implementation Plan

**Depends on:** `docs/specs/2026-08-12-stageglass-link-architecture.md`  
**Rule:** finish and validate each phase before expanding platforms. Use explicit derived-data paths and remove them after each build/test lane.

## Phase 0 — Release surface and naming boundary

- Add `LinkMode { link, ndi }` and a release-safe capability list.
- Change sender/receiver defaults and migrate stored QuicLink/WarpStream selections to Link.
- Show only **Link** and **NDI** in release UI. Remove room-code UI that exists only for unfinished transports.
- Exclude QuicLink/WarpStream from release factory and finder creation; optionally retain their code under `INTERNAL_EXPERIMENTS`.
- Add tests proving release capabilities contain exactly Link and NDI and legacy defaults migrate safely.

**Exit:** no release path can display or instantiate QuicLink/WarpStream; existing NDI behavior is unchanged.

## Phase 1 — Session and track seam

- Add the SDK-independent types and `MediaSession`/`LocalMediaSource` contracts from the architecture spec.
- Extract capture fan-out from `BroadcastController` without changing camera, preview, recorder, or NDI output behavior.
- Add `NDIMediaSession` around the existing NDI adapters.
- Refactor `ReceiverModel` selection to stable participant/track identity while presenting NDI as one synthetic track.
- Unit-test state transitions, track selection, capture fan-out, backpressure/drop behavior, teardown, and NDI mapping.

**Exit:** the shipping NDI workflow runs entirely through the new product-level session seam.

## Phase 2 — LiveKit Mac-to-Mac vertical slice

- Add pinned LiveKit Swift SDK dependency in one isolated change; record the chosen version and minimum OS requirements.
- Implement `LiveKitMediaSession` room connection, participant/track mapping, camera publishing, microphone publishing, subscription, video rendering, audio playback, and teardown.
- Add a development connection sheet for server URL, room, display name, and externally issued token. Redact token-bearing errors/logs.
- Feed outgoing and incoming media through the existing Sender and Receiver recorders.
- Add adapter tests with fakes at the application boundary; do not require a live cloud room for ordinary unit tests.

**Exit:** two Macs can complete a bidirectional A/V call and record both sides using manually issued credentials.

## Phase 3 — Reliability and release UX

- Make Link the default, with NDI as the explicit interoperability alternative.
- Handle mute/unmute, unpublish/republish, participant leave/rejoin, track replacement, server reconnect, permission denial, token expiry, and device switching.
- Add truthful connecting/reconnecting/failed states, participant/track labels, and actionable errors.
- Map LiveKit statistics into `TransportStats`; verify bounded queues and frame dropping under load.
- Run the quality gates: two-Mac hardware matrix, 30-minute soak, interrupted-network recovery, A/V sync, recordings, NDI regression, and release-build inspection for hidden experiments.
- Update product name, icon text, README, privacy copy, bundle identifiers, signing/notarization, recordings directory, and release automation in a separately reviewable migration.

**Exit:** signed macOS StageGlass Link candidate with WebRTC primary and working NDI interoperability.

## Phase 4 — StageGlass integration contract

- Implement a trusted token-service endpoint that issues short-lived, room-scoped publish/subscribe grants.
- Implement the versioned handoff payload using an opaque one-time code or equivalent authenticated IPC; do not place access tokens in URLs or logs.
- Let StageGlass launch Link into publish, subscribe, or both role and receive connection-state feedback.
- Define compatibility/version errors and standalone fallback when StageGlass is unavailable.
- Add contract tests for payload parsing, expiry, replay rejection, role permissions, redaction, and version negotiation.

**Exit:** StageGlass can safely create and launch a Link session without manual credential entry.

## Phase 5 — Apple mobile

- Extract the SDK-independent session/media core into a shared Swift package only after its macOS boundaries stabilize.
- Build receiver-first iPad/iPhone UI, then camera/mic publishing, using native LiveKit rendering where it improves power/performance while preserving application domain types.
- Reuse recorder logic with an iOS documents/share destination.
- Add local-network/camera/microphone privacy declarations, lifecycle handling, thermal/battery validation, orientation, and foreground/background behavior.

**Exit:** an Apple mobile device interoperates with Mac and StageGlass rooms for A/V receive, then publish, without NDI dependencies.

## Phase 6 — Android

- Mirror the session configuration, participant/track identity, state machine, and handoff schema in Kotlin; do not share platform SDK wrapper code.
- Implement LiveKit Android capture, publish, subscribe, rendering, audio, lifecycle, permissions, and recorder behavior.
- Add cross-platform room tests for Mac ↔ Android and Apple mobile ↔ Android plus token-role enforcement.

**Exit:** Android participates in the same StageGlass Link room contract with equivalent core operator behavior.

## Deferred backlog

After cross-platform A/V is stable: screen share, multi-view, effects/keys/transforms, richer slate metadata, adaptive quality controls, and scripted StageGlass cues. Re-evaluate each against the session/track model; do not revive custom transports as a prerequisite.
