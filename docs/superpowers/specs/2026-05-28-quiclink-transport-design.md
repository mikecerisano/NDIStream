# QuicLink: a loss-resilient transport alongside NDI (Historical)

> **Superseded 2026-08-12:** QuicLink is no longer a release direction. See `docs/specs/2026-08-12-stageglass-link-architecture.md`.

**Date:** 2026-05-28
**Status:** Design approved, pending spec review
**Codename:** "QuicLink" (UI label TBD — likely a "NDI / Direct" toggle)

## Goal

Add a second, optional video/audio transport to NDIStream that the user can switch
to instead of NDI. It targets the app's core use case — NDIStream sending to
NDIStream over an RF-hostile LAN (e.g. a GL.iNet travel router on a film set).

NDI stays in the app unchanged. QuicLink is additive: a toggle, not a replacement.
The user keeps NDI for interop (OBS, vMix, Resolume) and as the battle-tested
fallback; QuicLink is chosen when both ends are NDIStream.

## The problem it exists to solve

On a 2026 film job, NDI's failure mode was the dealbreaker — **not** bandwidth.
Running already at reduced quality (720p/540p) over wireless, a *single* dropped
frame on the congested set would cause NDI to freeze the entire image for **2–5
seconds**, then resume perfectly smooth — over and over. NDI's reliable transport
responds to packet loss by stalling to retransmit (head-of-line blocking) instead
of skipping ahead to live.

A film set is one of the most RF-hostile environments there is (comms, wireless
monitors, lav packs, phones — all contending for airtime), so packet loss is
**frequent and unavoidable**, even at low bitrate. The user's explicit tolerance:
losing a frame or two is fine; a multi-second freeze is not.

**The #1 design principle is therefore: timeliness over reliability — drop, never
stall.** Nothing in the pipeline ever waits for old data. This is the primary reason
QuicLink exists; everything else is secondary.

### Why it beats NDI for this use case

- **Loss resilience (the headline).** Stream-per-frame + a hard-deadline jitter
  buffer + an all-intra codec mean a lost frame costs exactly *that one frame* — the
  next frame paints normally. The multi-second freeze is *structurally impossible*
  because nothing waits for retransmission. NDI exposes no knob to get this behavior.
- **Bandwidth.** NDI's SpeedHQ is intraframe-only (~100–125 Mbps @ 1080p). All-intra
  HEVC at equivalent quality is meaningfully lower — roughly **2–3× less** (HEVC-intra
  beats SpeedHQ, but we forgo P-frame savings to keep frames independent; see GOP
  decision). Lower bitrate also means fewer packets exposed to RF loss.
- **No proprietary dependency:** removes `libndi.dylib`, the
  `disable-library-validation` entitlement, and the bundling step (for this path).
- **Encrypted by default:** QUIC mandates TLS 1.3; NDI is plaintext unless you pay
  for the enterprise tier.

### Where it does not beat NDI (explicit non-goals)

- **Not lower latency.** NDI's intraframe pipeline is already near-optimal
  (~one frame). HEVC encode + decode + jitter buffer will be *comparable* (tens of
  ms), possibly a hair higher. We match NDI here; we do not beat it.
- **Not interoperable.** QuicLink talks only to NDIStream. Anything needing OBS/vMix
  uses the NDI toggle. This is intentional.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Transport | QUIC via Network.framework | Congestion control + loss recovery + multiplexed streams + mandatory TLS, all built in. Available since macOS 12; our target is macOS 13. |
| Codec | HEVC, H.264 fallback | One codec per sender, chosen as the **lowest common denominator** across all connected receivers (HEVC only if every current receiver can decode it, else H.264). Preserves encode-once fan-out. |
| GOP structure | **All-intra** (every frame a keyframe) | Honors drop-never-stall: a dropped frame costs exactly one frame, never a freeze-until-keyframe. Rejected: interframe P-frames (smaller, but a dropped P-frame corrupts until the next keyframe — reintroduces the freeze). Rejected: dynamic-GOP "harden on loss" (unpredictable to tune). |
| Degradation under stress | **Congestion-adaptive bitrate/quality** | When QUIC signals congestion (rising RTT, loss, send-queue growth), lower the encoder bitrate (and resolution if needed), raise it back on recovery. Stays all-intra throughout. Picture softens gracefully instead of freezing — the "easy, predictable" half of adaptive, without switching codec structure. |
| Media-over-QUIC mapping | **A: stream-per-frame** now; datagrams + FEC (C) as **phase 2** | Stream-per-frame isolates slow/lost frames (no head-of-line blocking between frames). Phase 2 (QUIC unreliable datagrams + forward error correction) is the named next step for the harshest RF sets: it recovers lost packets *without* waiting for retransmit, reducing dropped-frame count, and sidesteps congestion-control over-throttling. Not required to eliminate the freeze (v1 already does), only to improve smoothness under heavy loss. |
| Audio | PCM (planar float) for v1 | Zero codec latency; ~3 Mbps stereo is trivial on LAN. Reuses the planar-float conversion the NDI sender already does. AAC is a later bandwidth option. |
| Multi-receiver | In scope | NWListener accepts multiple connections; encode once, fan encoded frames out to all. Matches NDI behavior, cheap to add. |
| Recording | Unchanged | Receiver decodes to a pixel buffer before delivery, so the existing recorder/display paths are untouched. Direct HEVC→.mov remux is a future optimization. |

## Architecture

### The abstraction seam

NDIStream's three ObjC classes already define the right boundary. Introduce three
Swift protocols; make both the NDI backend and the QuicLink backend conform.

- `VideoSender`
  - `init?(sourceName: String)`
  - `send(pixelBuffer:frameRateN:frameRateD:)`
  - `sendAudio(_ sampleBuffer: CMSampleBuffer)`
  - `stop()`
  - Mirrors the existing `NDISender` interface.
- `VideoReceiver` + `VideoReceiverDelegate`
  - Delegate delivers a **decoded, pixel-buffer-backed `CMSampleBuffer`** plus
    width/height/frameRate/fourCC, identical to `NDIReceiverDelegate`.
  - Also: `receiverDidDisconnect`, `receiverDidStallForSeconds:`, `receiverDidResume`,
    `receiverDidReceiveAudio:...`.
- `SourceFinder`
  - `onSourcesChanged: ([FoundSource]) -> Void`, `currentSources()`.
  - `FoundSource` carries `name`, `address`, and a `transport` tag (`.ndi` / `.quicLink`).

`BroadcastController` and `ReceiverModel` gain a `transport` selector and instantiate
the matching backend. Because the QuicLink receiver decodes before delivering, the
display layer (`AVSampleBufferDisplayLayer`) and `Recorder` paths require no changes.

### Roles

- **Sender = QUIC server** (`NWListener`), advertises over Bonjour.
- **Receiver = QUIC client** (`NWConnectionGroup` over `NWMultiplexGroup`), connects in.

### Sender pipeline (QuicLink)

`CameraManager` already emits `CVPixelBuffer`s. New chain:

1. **Encode** — `VTCompressionSession` → HEVC, or H.264 if *any* currently connected
   receiver lacks HEVC decode (lowest common denominator). A receiver that connects or
   drops can change the LCD, triggering a codec switch. Low-latency, all-intra config:
   - `kVTCompressionPropertyKey_RealTime = true`
   - `kVTCompressionPropertyKey_AllowFrameReordering = false` (no B-frames)
   - `kVTCompressionPropertyKey_MaxKeyFrameInterval = 1` (**all-intra** — every frame
     is a keyframe, so any frame is independently decodable and join-in-progress is
     instant)
   - `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` where available
   - `kVTCompressionPropertyKey_ExpectedFrameRate`
   - `kVTCompressionPropertyKey_AverageBitRate` — adjusted live for
     congestion-adaptive degradation (see Reliability).
2. **Packetize** — pull NAL units + parameter sets (HEVC VPS/SPS/PPS; H.264 SPS/PPS)
   from the encoded `CMSampleBuffer`; prepend a small header (frame type, pts, length).
3. **Send** — open one QUIC stream per frame (Approach A); fan the same encoded frame
   out to all connected receivers (encode once).
4. **Audio** — reuse the sender's existing planar-float conversion; send PCM on its
   own stream.

### Receiver pipeline (QuicLink)

1. **Discover** — `NWBrowser` on the Bonjour service type (e.g. `_ndistream._udp`) →
   `SourceFinder` list, merged in the UI with NDI sources, tagged by transport.
2. **Connect** — open the **control stream**; send capabilities (HEVC decode via
   `VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)`, max resolution); receive the
   chosen codec + dimensions + frame rate + parameter sets.
3. **Decode** — build a `VTDecompressionSession` from the parameter sets; reassemble
   each frame stream → decode → pixel-buffer-backed `CMSampleBuffer` → hand to the
   **existing delegate**. Display + recording unchanged.
4. **Jitter buffer** — small playout buffer ordered by pts; drop frames past deadline.

### Handshake & negotiation

A single control stream, opened by the receiver right after connect:

1. receiver → sender: capabilities (HEVC-decode yes/no, max resolution).
2. sender → receiver: chosen codec, dimensions, frame rate, parameter sets.
3. sender forces a keyframe.
4. Thereafter the control stream also carries tally and heartbeats.

This is a minimized WebRTC-style offer/answer for a two-party LAN.

### Reliability & reconnect

**Drop, never stall** is the governing rule here.

- **Hard-deadline jitter buffer.** Each frame carries a pts; the receiver holds a small,
  bounded playout buffer (absorbs jitter) and assigns each frame a deadline. A frame
  that misses its deadline is *dropped* and playback advances — the receiver never waits
  seconds for a late frame. With all-intra, the next frame decodes standalone, so a drop
  costs exactly one frame. This is the structural reason the NDI freeze cannot occur.
- **Stream-per-frame** means a stalled frame is abandoned, never propagated to later
  frames (no cross-frame head-of-line blocking).
- **Congestion-adaptive bitrate.** The sender watches QUIC's congestion signals (RTT
  trend, loss, send-queue depth) and lowers the encoder bitrate — and resolution if
  needed — under stress, raising it back on recovery. Degradation is a softer picture,
  never a freeze.
- QUIC provides congestion control and loss recovery for free; heartbeats on the control
  stream detect a dead peer; the receiver retains the resolved Bonjour endpoint and
  auto-reconnects, reusing the existing `receiverDidStall` / `receiverDidResume` UI states.

### UI

A transport toggle ("NDI / Direct") on both Sender and Receiver. The receiver's source
list shows NDI and QuicLink sources together, tagged. Persisted in UserDefaults
alongside the existing settings.

## Components (new files, mirroring `Sources/NDI/`)

- `Sources/Transport/VideoTransport.swift` — the three protocols + `FoundSource` + `Transport` enum.
- `Sources/QuicLink/QuicLinkSender.swift` — `NWListener`, fan-out, control stream.
- `Sources/QuicLink/QuicLinkReceiver.swift` — `NWConnectionGroup`, jitter buffer, decode.
- `Sources/QuicLink/QuicLinkFinder.swift` — `NWBrowser` / `NWListener` advertise.
- `Sources/QuicLink/VideoEncoder.swift` — `VTCompressionSession` wrapper.
- `Sources/QuicLink/VideoDecoder.swift` — `VTDecompressionSession` wrapper.
- `Sources/QuicLink/FrameProtocol.swift` — wire framing, headers, parameter-set carriage.
- `Sources/QuicLink/QuicTLS.swift` — self-signed identity generation + pinning.
- NDI backends get thin conformances to the new protocols (no behavior change).

## Risks / unknowns to resolve in planning (spikes)

1. **QUIC multi-stream model (RESOLVED by spike).**
   - Multi-stream QUIC = `NWMultiplexGroup(to: endpoint)` + `NWConnectionGroup(with:
     multiplex, using: params)`. Each stream is an `NWConnection`.
   - Open an outbound stream: `NWConnection(from: group)` then `.start(queue:)`. The
     listener receives each inbound stream as an `NWConnection` via
     `listener.newConnectionHandler`.
   - An `NWConnectionGroup` refuses to `.start()` unless a `newConnectionHandler` is set
     first.
   - Stream directionality is GROUP-WIDE, set via `NWProtocolQUIC.Options.direction`
     (e.g. `.bidirectional`) — it is NOT per-stream (confirms the forum note).
     Implication for QuicLink: one group cannot mix unidirectional media + bidirectional
     control with differing directions; either run everything `.bidirectional` in one
     group, or use two groups. Verified: 2 concurrent streams round-trip on loopback.
   - `NWProtocolQUIC.Options.isDatagram` exists (toggles datagram mode) — relevant to the
     phase-2 FEC path.
2. **Self-signed TLS + pinning (RESOLVED by spike).**
   - Identity (spike method): self-signed cert+key via system `openssl` (LibreSSL) →
     PKCS#12 → `SecPKCS12Import` → `SecIdentity` → `sec_identity_create`. NOTE:
     LibreSSL's default p12 PBE is the legacy format `SecPKCS12Import` accepts; modern
     OpenSSL's AES-256 PBE is rejected and would need `-legacy`.
   - Server attaches identity: `sec_protocol_options_set_local_identity(quic.securityProtocolOptions, identity)`.
   - Client pins: `sec_protocol_options_set_verify_block` — get the presented leaf via
     `SecTrustCopyCertificateChain`, compare SHA-256 of the leaf cert DER to the known
     pin, `complete(true/false)`. Do NOT call SecTrustEvaluate (it rejects self-signed).
   - Pin representation: spike uses full-cert-DER SHA-256 because `SecCertificateCopyKey`
     fails to extract some EC public keys (OSStatus -26275). Production should prefer
     RFC-7469 SPKI pinning (survives cert reissue) with a key type whose SPKI extracts
     cleanly.
   - Verified: correct pin → handshake succeeds + streams flow; wrong pin → TLS handshake
     fails (boringssl CERTIFICATE_VERIFY_FAILED / security error -9808), no usable stream.
   - Production follow-ups (NOT done in spike): generate the identity at runtime without
     shelling to openssl; distribute/verify the pin out-of-band (e.g. via the Bonjour TXT
     record, or trust-on-first-use).
3. **No QUIC-layer stream prioritization.** If audio competes with video, manage it
   with separate streams + app-level pacing.
4. **HEVC encode floor.** Hardware HEVC *encode* needs Kaby Lake+ / Apple Silicon;
   *decode* is ~universal since 2017. Fallback to H.264 keys off the encoder side.
5. **Congestion control vs. RF loss.** QUIC's congestion controller may mistake
   wireless-interference loss for bandwidth congestion and throttle bitrate more than
   necessary (a softer picture, never a freeze). If significant, the phase-2
   datagram+FEC path bypasses loss-based throttling. Measure on a real congested set.

## Testing

- **Unit:** `FrameProtocol` round-trip (packetize → depacketize), capability
  negotiation logic, jitter-buffer ordering/drop.
- **Integration (loopback):** sender + receiver in one process over QUIC on localhost;
  assert frames decode and dimensions/fps match.
- **Manual on hardware:** two Macs over the travel router — verify discovery, connect,
  live video, HEVC-vs-H.264 fallback, multi-receiver, reconnect after wifi blip, and
  measured bandwidth vs NDI for the same scene.

## Out of scope (v1)

- QUIC datagram + FEC "harsh-RF" mode — **phase 2**, the named next step if v1's
  drop-don't-stall still leaves too many visible dropped frames on the worst sets.
- Direct HEVC→.mov remux on record (decode-then-existing-path for now).
- AAC audio (PCM for now).
- Direct interop with non-NDIStream tools. (Note: a receiver-side **virtual camera**
  output — letting OBS/Zoom/etc. pick up any received source as a system camera, via a
  `CMIOExtension` Camera Extension — is the **planned next initiative after QuicLink**.
  It is orthogonal to the transport (works for any received source, NDI or QuicLink) and
  gets its own spec rather than being folded in here.)
