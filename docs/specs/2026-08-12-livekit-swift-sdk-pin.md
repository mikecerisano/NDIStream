# LiveKit Swift SDK Pin

**Decision date:** 2026-08-12  
**Pinned version:** `2.16.0`  
**Package:** `https://github.com/livekit/client-sdk-swift.git`

The StageGlass Link macOS target pins LiveKit's official Swift SDK exactly rather than using a moving version range. The SDK supports macOS 10.15 and newer; this application remains at its existing macOS 13 deployment target.

The initial adapter proves these application boundaries compile against the pinned SDK:

- connect/disconnect and connection-state callbacks;
- publish the application's existing `CVPixelBuffer` camera stream through `LocalVideoTrack.createBufferTrack` and `BufferCapturer`, avoiding a second camera session;
- enable/disable LiveKit microphone publication;
- enumerate remote participants and tracks using stable participant and track IDs;
- subscribe to a selected remote video track and return pixel buffers to the existing display/recording pipeline;
- redact the access token from errors returned across the adapter boundary.

The dependency and adapter do not make Link operator-visible by themselves. Shipping connection UI and the application-owned `MediaSession` contract land in the release-surface/session phases. Hardware validation still requires externally issued tokens and two Macs connected to a real LiveKit room.
