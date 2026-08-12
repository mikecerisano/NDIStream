# WarpStream: third transport for the NDI vs QuicLink vs WarpStream shootout (Historical)

> **Superseded 2026-08-12:** WarpStream is no longer a release direction. See `docs/specs/2026-08-12-stageglass-link-architecture.md`.

**Date:** 2026-06-04
**Status:** Design approved, pending spec review
**Codename:** "WarpStream" (UI label confirmed — segmented control reads `NDI | QuicLink | WarpStream`)

## Goal

Add WarpStream as a third concurrent transport in NDIStream, alongside the
existing NDI and in-progress QuicLink paths. The purpose is **a head-to-head
shootout** of the three transports — same camera, same Mac, same network —
using NDIStream as the harness on both sides (sender and receiver).

WarpStream itself lives in a separate Swift package
(`Low_Latency_UDPstreaming/`) and is being developed in parallel by a partner.
This spec defines:

1. **The public API surface WarpStream must expose** so NDIStream can adopt it as
   a peer transport. WarpStream's author codes to this contract.
2. **The NDIStream-side changes** to accept the third transport and present it
   in the UI.
3. **The shootout instrumentation** — multi-component stats — that lets the
   three transports be compared meaningfully rather than guessed at.

NDIStream is the *design driver*. WarpStream's internals (codec, FEC,
congestion control, wire format) are entirely WarpStream's domain; this spec
constrains only the public Swift API.

## Why this exists

NDIStream's transport layer was deliberately abstracted during the QuicLink
work (see `VideoTransport.swift`: `VideoTransportKind { .ndi, .quicLink }`,
plus `VideoSender` / `VideoReceiver` / `SourceFinder` protocols and a
`TransportFactory`). That abstraction was always meant to allow swapping in
additional transports. WarpStream is the third.

The shootout matters because:

- **NDI** is the industry baseline. Interoperable, battle-tested, but with the
  drop-frame-causes-multi-second-freeze failure mode the QuicLink spec
  documents in detail.
- **QuicLink** is the partner's first attempt at a loss-resilient replacement,
  designed around "drop, never stall" using QUIC streams + all-intra HEVC.
- **WarpStream** is the user's own low-latency QUIC design, targeting 60–80ms
  glass-to-glass, with its own approach to clock sync, codec, and discovery.

Without three peers running in the same harness, with the same camera, on the
same LAN, with comparable instrumentation, "which is better" is a vibes
question. With this integration it becomes a numbers question.

## Non-goals

- **Not a redesign of NDIStream's UI.** The Sender/Receiver windows stay
  one-purpose. We add a transport picker and a room-code field; that's it.
- **Not a WarpStream feature spec.** Codec choice, congestion control, FEC,
  retransmission strategy, PSK derivation algorithm — all WarpStream's domain.
  This spec sees only the public Swift surface.
- **Not a replacement for QuicLink.** Both QuicLink and WarpStream remain as
  separate transports. NDI also remains. All three are first-class.
- **Not a server / relay design.** If WarpStream's room-code path requires
  STUN/TURN/relay infrastructure for cross-network use, that lives in
  WarpStream's spec, not this one (open question Q5 below).
- **Not interoperable beyond NDIStream↔NDIStream for the new transports.**
  Same as QuicLink — WarpStream talks only to NDIStream-as-receiver.

## Architecture

### The abstraction seam (already exists)

`Sources/Transport/VideoTransport.swift` already defines:

- `VideoTransportKind` — currently `{ .ndi, .quicLink }`; this spec adds
  `.warpStream`.
- `FoundSource` — discovered source descriptor; this spec adds an optional
  `roomCode: String?` field alongside existing `port`/`pinSHA256`.
- `VideoSender`, `VideoReceiver`, `VideoReceiverDelegate`, `SourceFinder` —
  protocols that all three transports conform to via thin adapters.
- `TransportFactory` — switches over `VideoTransportKind` to return the right
  backend. Today `.quicLink` returns `nil` (until QuicLink wires up);
  `.warpStream` joins the switch.

The shape WarpStream conforms to is therefore already defined. The only
additions are:

- A new `Sources/Transport/WarpStreamTransport.swift` containing the three
  adapter classes (`WarpStreamVideoSender`, `WarpStreamVideoReceiver`,
  `WarpStreamSourceFinder`).
- Two surgical edits to existing files (`VideoTransport.swift` adds the enum
  case + struct field; `NDITransport.swift`'s `TransportFactory` adds branches).

### Three transports, three concurrent finders

The Receiver window today runs one `SourceFinder` (NDI). With QuicLink and
WarpStream both bringing their own discovery, the factory's `makeFinder()`
becomes `makeFinders() -> [SourceFinder]`. The `ReceiverModel` runs all three
concurrently, merges their `onSourcesChanged` callbacks into a single source
list keyed by `(transport, name)`, and filters the dropdown by the
currently-selected transport.

Operational note: the added mDNS chatter from three concurrent finders is
trivial — well under 1 kbit/sec averaged, dominated by NDI's existing
discovery traffic on any real set network. See **Operational notes** below.

## WarpStream public API contract

The Swift surface WarpStream must expose so NDIStream can wrap and consume it.
All types are `public` in their target.

### Sender (in `WarpStreamSender` target)

```swift
public final class WarpStreamSender {
    /// Generates a fresh room code on init, derives a PSK from it, publishes
    /// Bonjour service _warpstream._udp.local. with TXT carrying name, code,
    /// and PSK fingerprint. Begins listening for incoming receivers.
    public init(sourceName: String,
                clockVideo: Bool,
                targetResolution: WarpStreamResolution,
                targetFrameRate: Int) throws

    /// The active room code. NDIStream displays this in the Sender window so
    /// the operator can share it out-of-band with the receiver Mac.
    public var roomCode: String { get }

    public func send(pixelBuffer: CVPixelBuffer, frameRateN: Int32, frameRateD: Int32)
    public func repeatLastFrame(frameRateN: Int32, frameRateD: Int32)
    public func sendAudio(_ sampleBuffer: CMSampleBuffer)
    public func stop()
    public func currentStats() -> TransportStats
}

public enum WarpStreamResolution {
    case native, p720, p540
}
```

### Receiver (in a new `WarpStreamReceiver` target)

```swift
public protocol WarpStreamReceiverDelegate: AnyObject {
    func warpStreamReceiver(_ r: WarpStreamReceiver,
                            didReceive sampleBuffer: CMSampleBuffer,
                            width: Int32, height: Int32,
                            frameRateN: Int32, frameRateD: Int32, fourCC: UInt32)
    func warpStreamReceiverDidDisconnect(_ r: WarpStreamReceiver)
    func warpStreamReceiverDidStall(_ r: WarpStreamReceiver, forSeconds seconds: Int)
    func warpStreamReceiverDidResume(_ r: WarpStreamReceiver)
    func warpStreamReceiver(_ r: WarpStreamReceiver,
                            didReceiveAudio samples: UnsafePointer<Float>,
                            sampleRate: Int32, channels: Int32,
                            samplesPerChannel: Int32, channelStrideBytes: Int32)
}

public final class WarpStreamReceiver {
    public weak var delegate: WarpStreamReceiverDelegate?

    /// LAN connection via Bonjour-discovered source. Uses host/port/pskFingerprint
    /// from the discovered source. Verifies the PSK fingerprint matches what the
    /// receiver derives locally from `discovered.roomCode`.
    public init?(discovered: WarpStreamDiscoveredSource)

    /// Manual connection via room code. Derives PSK locally. Resolution of how
    /// the receiver actually reaches the sender (LAN scan + STUN + TURN + ...)
    /// is internal to WarpStream — see open question Q5.
    public init?(roomCode: String)

    public func stop()
    public func currentStats() -> TransportStats
}

public struct WarpStreamDiscoveredSource: Equatable {
    public let name: String
    public let host: String
    public let port: UInt16
    public let pskFingerprint: Data    // SHA-256 of derived PSK; used by receiver to verify
    public let roomCode: String        // surfaced so UI can show "or join: ABC123"
}
```

### Finder (in `WarpStreamReceiver` target or shared)

```swift
public final class WarpStreamFinder {
    public var onSourcesChanged: (([WarpStreamDiscoveredSource]) -> Void)?
    public init()
    public func currentSources() -> [WarpStreamDiscoveredSource]
    public func stop()
}
```

### Multi-component stats (shared across transports)

```swift
public struct TransportStats {
    public let bitrateKbps: Double

    // Latency components, milliseconds. nil where not measurable on this transport.
    public let sendLatencyMs: Double?       // capture → first byte to socket
    public let wireLatencyMs: Double?       // sender socket → receiver socket (needs clock sync)
    public let receiveLatencyMs: Double?    // socket → frame delivered to delegate
    public let endToEndLatencyMs: Double?   // PTS-delta direct, ≈ sum of the above
    public let jitterBufferMs: Double?      // current buffer depth (a setting, not a latency)

    public let framesDropped: UInt64
    public let cpuPercent: Double
}
```

`TransportStats` should live in a place all three transports can depend on
(probably `WarpStreamProtocol`, copied/mirrored into QuicLink). NDI's adapter
synthesizes a `TransportStats` from whatever NDI exposes — likely only
`bitrateKbps`, `endToEndLatencyMs`, `framesDropped`, and `cpuPercent`. The
finer breakdown reads nil for NDI; the stats overlay renders "—". That's
acknowledged and fine — NDI is the closed-source baseline.

### Bonjour service + TXT record schema

- Service type: `_warpstream._udp.local.`
- TXT record keys:
  - `src` — source name (UTF-8)
  - `code` — room code (6 uppercase alphanumeric chars, no `0/O/1/I/L`)
  - `pskfp` — PSK fingerprint hex (so receiver can verify PSK derivation)
- Port carried by SRV record automatically (Network.framework's NWListener).

## NDIStream-side changes

### Code changes

**`Sources/Transport/VideoTransport.swift`** — two surgical edits:

- `VideoTransportKind` gains `.warpStream` case.
- `FoundSource` gains `roomCode: String?` (default `nil`), alongside existing
  `port` and `pinSHA256`.

**New file `Sources/Transport/WarpStreamTransport.swift`** — mirrors
`NDITransport.swift`:

- `WarpStreamVideoSender: VideoSender` — wraps `WarpStreamSender`; exposes the
  underlying `roomCode` so the Sender UI can display it.
- `WarpStreamVideoReceiver: NSObject, VideoReceiver, WarpStreamReceiverDelegate`
  — wraps `WarpStreamReceiver`, translates delegate callbacks 1:1 to
  `VideoReceiverDelegate`. Two init paths matching the underlying SDK:
  discovered and room-code.
- `WarpStreamSourceFinder: SourceFinder` — wraps `WarpStreamFinder`, maps
  `WarpStreamDiscoveredSource → FoundSource(transport: .warpStream, ...)`
  including `roomCode`. Mirrors `NDISourceFinder.mapForTesting` pattern with a
  pure-function test seam.

**`Sources/Transport/NDITransport.swift` (`TransportFactory`)** — extend:

- `makeSender(transport:sourceName:clockVideo:)` adds `.warpStream` branch.
  Signature grows to accept `WarpStreamResolution` and `targetFrameRate` (or
  hold a config struct; see Q7).
- `makeReceiver(for: FoundSource)` adds `.warpStream` branch. **Routing rule**:
  if `source.port != nil` → `WarpStreamReceiver(discovered:)`; else → 
  `WarpStreamReceiver(roomCode:)`. Same rule applies if QuicLink ever supports
  manual-code entry.
- `makeFinder()` becomes `makeFinders() -> [SourceFinder]` returning all three
  finders. `ReceiverModel` updated to consume an array.

### Model changes

**`Sources/Receive/ReceiverModel.swift`**:

- Hold all three finders simultaneously.
- Merge `onSourcesChanged` callbacks into one source list keyed by
  `(transport, name)`.
- Add `@Published var selectedTransport: VideoTransportKind` — persisted to
  `UserDefaults` key `"receiver.transport"`, defaults to `.ndi` on first launch.
- Filter the dropdown source list by `selectedTransport`.
- Add `connectByRoomCode(_ code: String)` — synthesizes
  `FoundSource(transport: selectedTransport, name: "Code: \(code)", address: "", port: nil, roomCode: code)`
  and routes through `TransportFactory.makeReceiver`.

**Sender-side model** (`Sources/Capture/CameraManager.swift` or equivalent):

- Add `selectedTransport: VideoTransportKind` — persisted to `"sender.transport"`,
  defaults to `.ndi`.
- When broadcasting starts with `.warpStream`, read `WarpStreamVideoSender.roomCode`
  and publish for UI display.

### UI changes — Receiver window

- Segmented control at top: `[ NDI | QuicLink | WarpStream ]` bound to
  `selectedTransport`.
- Source dropdown stays; now filtered to active transport.
- Below the dropdown, shown only when transport is `.warpStream` (and
  optionally `.quicLink` if QuicLink wants the same affordance): a `TextField`
  labeled "Or join by code:" + a "Connect" button. Validates code format
  client-side (6 chars, allowed alphabet).

### UI changes — Sender window

- Same segmented transport picker at top.
- When `.warpStream` selected AND broadcasting: display the active room code
  as large copyable text with a "Copy" button — operator shares it
  out-of-band with the receiver Mac.
- Quality preset (Native / 720p / 540p) and frame rate (30 / 60) pickers stay;
  values passed through to `WarpStreamSender.init`.

### What does not change

- Camera capture, audio capture, smooth-pacing toggle (hidden when transport
  is `.warpStream` if WarpStream has no equivalent — Q9), menu bar controls
  — all transport-agnostic.
- Recording behavior — see verification section below.
- The existing `Sources/QuicLink/` directory — untouched.
- The `NDI/` ObjC sources — untouched.

## Discovery + connection flow

Two paths into a WarpStream session:

**Bonjour path (LAN):**

1. Sender publishes `_warpstream._udp.local.` with TXT (`src`, `code`,
   `pskfp`).
2. `WarpStreamFinder` browses, resolves SRV/TXT, emits
   `WarpStreamDiscoveredSource`.
3. `WarpStreamSourceFinder` adapter maps to
   `FoundSource(transport: .warpStream, port: …, pinSHA256: pskfp, roomCode: code)`.
4. User picks from dropdown → `TransportFactory.makeReceiver` sees `port != nil`
   → invokes `WarpStreamReceiver(discovered:)`.
5. WarpStream verifies PSK fingerprint matches local derivation from room code,
   completes TLS-PSK handshake, begins streaming.

**Manual room-code path (cross-network / firewalled):**

1. Sender's Sender-window UI shows the room code (e.g. `ABC123`).
2. Operator shares the code with the receiver Mac out-of-band (text, Slack,
   verbal).
3. Receiver user enters code in "Or join by code" field, hits Connect.
4. `ReceiverModel.connectByRoomCode` synthesizes a `FoundSource` with only
   `roomCode` set (no port, no pin).
5. `TransportFactory.makeReceiver` sees `port == nil` → invokes
   `WarpStreamReceiver(roomCode:)`.
6. How WarpStream actually reaches the sender from there (STUN/TURN/relay/LAN
   scan) is WarpStream's internal concern. See Q5.

**Factory decision rule** is deliberately dumb and deterministic: branch on
`FoundSource.port != nil`. Keeps NDIStream's code transport-agnostic beyond
the enum switch.

## Recording verification

Today's recording works as follows:

- **Sender-side**: captures from `CameraManager` (camera + mic), encodes H.264
  → `.mov` in `~/Movies/NDIStream/`. Transport-agnostic — already works for all
  three.
- **Receiver-side**: tees off `VideoReceiverDelegate.didReceive(sampleBuffer:...)`
  and the audio delegate callback. Encodes to H.264 `.mov`. All three transports
  feed the same delegate.

**Verification (Approach C piece, smoke tests only):**

- **Pixel format compatibility.** Confirm the recording encoder accepts what
  each transport delivers (NDI: UYVY; QuicLink: NV12; WarpStream: NV12 per
  Q6). Test: 10-second recording on each, play back, check for color shift or
  rejection.
- **Frame-rate metadata.** Confirm `frameRateN/frameRateD` propagate
  correctly into the recorded `.mov` for each transport.
- **Audio format.** Confirm Float32 PCM @ 48 kHz routes through the recording
  audio track without resampling artifacts for each transport.

No code changes expected for recording. If the smoke tests reveal a
pixel-format mismatch (e.g. WarpStream delivers UYVY instead of NV12), the
fix lives in the WarpStream adapter, not the recording layer.

## Stats overlay & multi-component latency

The shootout requires instrumentation. Without it, three transports look the
same in three windows and "which is better" reduces to vibes.

### Why multi-component, not single-number

A single "Latency: 62 ms" number doesn't tell you *where* the time goes. The
breakdown does:

```
Send:    12 ms  ← sender's encoder + socket-push cost
Wire:    18 ms  ← actual network travel time
Receive: 32 ms  ← jitter buffer (24) + decode (8)
─────────────
End-to-end: 62 ms
```

That breakdown immediately surfaces "WarpStream's wire is faster than NDI's
but its decoder is heavier" — an actionable finding. A single 62ms number
gives nothing to act on.

### Measurement technique alignment

To compare numbers across transports, the **technique** has to match, not
just the units. The spec adopts:

- **PTS-delta with clock sync** for `endToEndLatencyMs`. Each frame carries
  the sender's capture-time PTS; receiver subtracts its own wall-clock at
  decode time. Requires clock sync (NTP-style or in-protocol; WarpStream's
  `ClockSync.swift` provides this).
- **Component latencies** (`send`, `wire`, `receive`) measured directly within
  each transport using its own internal timestamps. `wire` requires sender +
  receiver clock sync; the others are local-only.
- **Until clock sync converges** (first few seconds after connect),
  clock-dependent fields report `nil` → overlay renders "—".

NDI is acknowledged as the special child: it exposes its own end-to-end
latency but not the finer breakdown. The NDI adapter populates
`endToEndLatencyMs` and leaves `send`/`wire`/`receive` nil. That's a known
gap, documented in the overlay legend.

### Overlay placement & behavior

- Lives in both Sender and Receiver windows.
- Off by default. Toggle: View menu → "Show Stats" + `⌘I` keyboard shortcut.
- Translucent overlay, top-right corner, eight lines (bitrate, four latency
  components, jitter buffer depth, frames dropped, CPU%).
- Refresh: 1 Hz via `Timer` polling `currentStats()`. 1 Hz is cheap and
  non-distracting.
- Sender side: `wireLatencyMs` and `endToEndLatencyMs` are nil from the
  sender's POV (no round-trip view), but `sendLatencyMs` is meaningful.

## Operational notes

### mDNS chatter from three concurrent finders

Running three Bonjour finders simultaneously adds minimal LAN multicast
traffic:

- Each finder issues an initial PTR query plus SRV/TXT lookups per discovered
  source, then refresh queries roughly every ~60s while idle.
- Estimated added load from the WarpStream finder on top of NDI + QuicLink:
  well under 100 bytes/sec averaged.
- NDI's own discovery (mDNS + custom UDP discovery on port 5960) is the
  dominant LAN-multicast user on any real production network. The
  QuicLink + WarpStream finders combined are quieter.
- On the GL.iNet travel-router setup the app was originally designed for,
  this is undetectable. Only relevant on enterprise APs with aggressive
  mDNS reflector limits, and even there NDI would hit the limit first.

No special handling required.

### Concurrent transports in the same app

NDI and QuicLink can in principle both run simultaneously (NDIStream supports
opening Sender and Receiver windows independently). WarpStream joins that
model. The app does not currently support a single Sender broadcasting on
multiple transports at once; that's out of scope.

## Testing strategy

### Unit tests in NDIStream

- `WarpStreamSourceFinder` mapping: `WarpStreamDiscoveredSource → FoundSource`
  correctness via a `mapForTesting` seam analogous to
  `NDISourceFinder.mapForTesting`.
- `TransportFactory` routing: `FoundSource` with `port + pin` → invokes
  `WarpStreamReceiver(discovered:)`; `FoundSource` with `roomCode` only →
  invokes `WarpStreamReceiver(roomCode:)`.
- `ReceiverModel` transport filtering: mixed source list, only sources matching
  `selectedTransport` appear in the dropdown.
- UserDefaults persistence for `selectedTransport` (sender + receiver
  separately).
- Room code format validation in the manual-entry field (6 chars, allowed
  alphabet).

### Integration tests in NDIStream

- **Loopback smoke** (`#if canImport(WarpStreamReceiver)`-gated until WarpStream
  ships): WarpStream sender + receiver on the same Mac, send a 1-frame test
  pattern, assert receiver delegate fires with matching dimensions/fourcc.
- **Recording smoke per transport**: drive the receiver with a synthetic
  `CMSampleBuffer` stream, assert the `.mov` file is created, non-zero size,
  and readable by `AVAsset`. One test per transport.

### Manual shootout protocol (a checklist, not code)

1. Two Macs on the same LAN.
2. Both pointed at the same calibrated reference monitor displaying a
   high-frame-rate stopwatch.
3. Sender Mac broadcasts the stopwatch via the chosen transport (`NDI`,
   `QuicLink`, or `WarpStream`).
4. Receiver Mac displays the stream, alongside the same reference monitor
   if possible.
5. Slow-mo phone camera captures both displays; latency = pixel delta read off
   the slow-mo footage.
6. During the 60-second run, capture: stats overlay screenshot, receiver `.mov`
   recording, Activity Monitor CPU% per process.
7. Repeat for all three transports.
8. Cross-reference slow-mo measured latency vs. stats overlay's claimed
   end-to-end latency for sanity-check.

Document results in a follow-up note. The shootout is the first user-facing
moment of truth for whether WarpStream beats NDI.

## Open questions for the WarpStream author

Each has a proposed default so the spec isn't blocked. WarpStream's author
confirms or counters.

**Q1. Latency reporting alignment.** *Confirmed in design discussion.* Both
WarpStream and QuicLink commit to multi-component reporting via PTS-delta with
clock sync. NDI is exempt — exposes end-to-end only.

**Q2. Room code format.** Proposed: 6-char uppercase alphanumeric, no
`0/O/1/I/L`. ~1.5B combinations after exclusions. Confirm.

**Q3. Room code lifecycle.** Proposed: auto-generated fresh on each
`Start Broadcasting`. Sticky/operator-settable codes are a v2 feature.
Confirm.

**Q4. Bonjour service type + TXT schema.** Proposed:
`_warpstream._udp.local.` with TXT keys `src`, `code`, `pskfp`. Port via SRV.
Confirm.

**Q5. Cross-network connection model.** *Material product decision.* When
the receiver enters a room code for a sender on a different network, how is
the connection actually made?

- Options: STUN + hole-punching only; STUN with TURN relay fallback; LAN-only
  (room code is convenience, not remote access).
- This determines what the "join by code" affordance promises the operator.
- If the answer is LAN-only for now, the Receiver window's helper text says so
  ("Or join by code (same network):").
- WarpStream's author owns the answer; this spec accommodates whichever path
  is chosen.

**Q6. Pixel format + audio format delivered to delegate.** Proposed:

- Video: NV12 (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`).
- Audio: Float32 PCM, 48 kHz, deinterleaved per-channel, channel count
  reported in delegate callback.

Confirm.

**Q7. Quality preset / bitrate target API.** Proposed: `WarpStreamSender.init`
takes `targetResolution: WarpStreamResolution` and `targetFrameRate: Int`.
NDIStream's existing Quality and Frame Rate pickers map directly. Confirm; or
counter-propose a target-bitrate API if WarpStream prefers continuous control.

**Q8. Codec choice (informational).** Proposed: H.264 first, for parity with
QuicLink and Intel-Mac compatibility. HEVC and AV1 are A/B candidates for a
later shootout iteration.

**Q9. Smooth pacing parity.** NDI has a smooth-pacing toggle. If WarpStream
has no equivalent (pacing always optimal/automatic), the toggle is hidden
when transport is `.warpStream`. Confirm.

## Out of scope (explicit)

- WarpStream's internal codec, encoder settings, congestion control, FEC,
  retransmission strategy.
- PSK derivation algorithm (HKDF/PBKDF2/etc.) — security detail not
  API-visible to NDIStream.
- WarpStream's wire format, packet structure, control message design.
- QuicLink's design — left untouched, except QuicLink's owner may want to
  align on `TransportStats` reporting (Q1) for the shootout.
- Server/relay infrastructure for cross-network room-code connections (lives
  in WarpStream's design, not here — Q5).
- A single Sender broadcasting on multiple transports simultaneously (open
  separate Sender windows per transport if needed).
- Codec A/B shootout within WarpStream (H.264 vs HEVC vs AV1) — a future
  iteration once the three-transport baseline is established.
