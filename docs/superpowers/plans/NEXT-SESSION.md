# QuicLink — Historical Next Session TODO

> **Superseded 2026-08-12:** QuicLink is no longer a release direction. StageGlass Link uses LiveKit/WebRTC as its primary transport and retains NDI on macOS. See `docs/specs/2026-08-12-stageglass-link-architecture.md` and `docs/plans/2026-08-12-stageglass-link-phased-plan.md`. Do not execute the tasks below for release work.

_Last updated: 2026-05-28. Branch: `feature/quiclink-foundations` (not merged to `main`)._

## Where things stand

QuicLink is a custom QUIC/HEVC video transport being added alongside NDI, built to **drop frames, never freeze** (the NDI failure mode that motivated it). Design + rationale: `docs/superpowers/specs/2026-05-28-quiclink-transport-design.md`.

**Done and green (19 tests, 0 failures):**
- **Plan 1** — primitives: `FrameProtocol`/`VideoPacket`, `VideoEncoder`/`VideoDecoder` (all-intra HEVC), `JitterBuffer` (drop-don't-stall), plus the QUIC + TLS spike (`Tests/Spikes/QuicLoopbackSpikeTests.swift`).
- **Plan 2a** — abstraction seam: `VideoSender`/`VideoReceiver`/`SourceFinder` protocols + `FoundSource` + `VideoTransportKind`; NDI adapters; `BroadcastController`/`ReceiverModel` rewired to the seam (NDI still the default). ⚠️ Manual NDI smoke test NOT yet run — see TODO 2.
- **Plan 2c (core)** — `QuicLinkSender`, `QuicLinkReceiver`, `QuicLinkFinder`, `QuicTLS`. **Works end-to-end on loopback** (encode → QUIC → decode), proven by `QuicLinkLoopbackTests` (5+ consecutive passes).

Build/test (XcodeGen project; repo dir path has a trailing space — quote it):
```bash
xcodegen generate
xcodebuild test -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS'
```

## TODO (in order)

### 1. Wire QuicLink into the seam — Plan 2c Task 6 (NOT done)
The QuicLink classes work in isolation but aren't selectable in the app yet.
- [ ] `TransportFactory` (`Sources/Transport/NDITransport.swift`): implement the `.quicLink` branches — `makeSender` → `QuicLinkSender(sourceName:)`; `makeReceiver(for:)` → `QuicLinkReceiver(host: source.address, port: source.port!, pinSHA256: source.pinSHA256!)`. Currently they return `nil`.
- [ ] Replace `makeFinder()` with `makeFinders() -> [SourceFinder]` returning `[NDISourceFinder(), QuicLinkFinder()]`.
- [ ] `ReceiverModel` (`Sources/Receive/ReceiverModel.swift`): run multiple finders and merge their `onSourcesChanged` outputs into `availableSources` (each `FoundSource` is already tagged by transport). Keep the existing auto-select logic on the merged list.
- [ ] Build + full suite green.

### 2. NDI smoke test — Plan 2a Task 5 (manual, at the Mac)
- [ ] Launch the app; broadcast a camera over NDI, receive it, record both sides. Confirm the Plan 2a seam refactor didn't disturb the working NDI path. (Automated tests can't cover live NDI.)

### 3. Plan 2d — UI + hardening + hardware
- [ ] UI "NDI / Direct" transport toggle on Sender + Receiver; merged source list tagged by transport.
- [ ] Congestion-adaptive bitrate (lower encoder bitrate under QUIC congestion signals; stay all-intra).
- [ ] Multi-receiver fan-out hardening + H.264 fallback / capability negotiation (deferred from 2c).
- [ ] **Two-Mac hardware validation** — the real payoff: confirm drop-don't-stall beats NDI's freeze on a congested set; measure bandwidth vs NDI; measure handshake/glass-to-glass latency.

## Known follow-ups / tech debt

- **Fresh identity per launch:** `QuicTLS.loadOrCreate()` now generates a new short-lived `CN=localhost` identity each launch (reloading a persisted p12 left Network.framework QUIC stuck before the verify block — the loopback root cause). Consequence: a sender restart changes its cert pin, so the **receiver must re-read the Bonjour TXT pin on reconnect** (handle in 2d reconnection logic). `loadOrCreate` is now a slight misnomer (always creates).
- **NWConnectionGroup unreliable here:** `QuicLinkReceiver` uses a plain client-opened `NWConnection` request/reply pull loop, not `NWConnectionGroup` (the group path wouldn't reach `.ready` reliably in this class even after matching the spike's options). Keep the pull loop.
- **Audio deferred:** `QuicLinkSender.sendAudio` is a no-op. Implement PCM-over-QUIC in 2d.
- **Codec negotiation deferred:** sender always encodes HEVC; receiver decodes per the packet's codec byte. Add H.264 fallback + the control-stream capability handshake in 2d.
- **Encoder emission:** confirm the streaming send path doesn't force per-frame `VTCompressionSessionCompleteFrames` (that was a Plan-1 test-only shim; adds latency in a live stream).
- **Endpoint host:** build IP-literal endpoints, not `NWEndpoint.Host(<String var>)` (which makes a DNS `.name` that never connects on loopback) — already handled in `QuicLinkReceiver`; remember for any new connect path.

## Reference docs
- Design spec: `docs/superpowers/specs/2026-05-28-quiclink-transport-design.md`
- Plan 1: `docs/superpowers/plans/2026-05-28-quiclink-foundations.md`
- Plan 2a: `docs/superpowers/plans/2026-05-28-quiclink-plan2a-abstraction-seam.md`
- Plan 2c: `docs/superpowers/plans/2026-05-28-quiclink-plan2c-transport-core.md`
- Codex investigation brief (loopback handshake, now resolved): `docs/superpowers/plans/2026-05-28-quiclink-loopback-codex-investigation.md`
