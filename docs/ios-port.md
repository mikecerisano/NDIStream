# StageGlass Link for Apple Mobile

**Status:** receiver foundation implemented; app UI target still pending.

**Why:** On a film set, the off-camera scene partner needs to see the on-camera actor (for fake-Zoom gags, video village, eyelines, playback proxies). Today that's a second MacBook. An iPad on a c-stand or magic-arm replaces the laptop — smaller, lighter, silent, ~10hr battery, easier to mount.

**Scope:** **Receiver-first.** `StageGlassLinkCore` is now a Swift package that builds
for iOS/iPadOS and macOS. It owns room connection, remote-track projection,
deterministic camera selection, matching microphone selection, subscription, and
rendering-facing `CMSampleBuffer` callbacks. It deliberately owns no capture graph.

The existing macOS app keeps its single `CameraManager`; its adapter to
`LocalMediaSource` remains outside the portable package. A mobile sender will receive
the same explicit platform capture adapter later. Do not add a second camera session
or enable LiveKit microphone capture alongside an application-owned microphone graph.

## Functional spec

Single-screen iPad app, landscape-first.

- **Top bar (compact, ~44 pt):**
  - Source picker — dropdown of discovered NDI sources
  - Connect / Disconnect button
  - Status text — "1920×1080 @ 30 • UYVY" or "Source offline"
  - Record button + timer + share-sheet trigger (replaces the macOS "Reveal in Finder" affordance — iOS has no concept of revealing in Finder)
- **Video area:** fills the rest of the screen. `AVSampleBufferDisplayLayer`. Black background. Letterboxed `.resizeAspect`.
- **Lock-screen behavior:** keep screen awake while connected (`UIApplication.shared.isIdleTimerDisabled = true`). Release when disconnected.

## Shared WebRTC foundation

- Package product: `StageGlassLinkCore`
- Minimum platforms: iOS/iPadOS 15, macOS 13
- LiveKit Swift: pinned to 2.16.0
- Primary mobile entry point: `LinkReceiverSession`
- Callbacks: selected remote video and audio as `CMSampleBuffer`
- Runtime token remains caller-provided and is never Codable

The package is intentionally independent of NDI and AppKit. This gives iPhone and
iPad the same room/track semantics without linking the macOS NDI runtime.

## NDI-specific reuse (later, optional)

Should port largely as-is:
- `NDIFinder.h/.mm`, `NDIReceiver.h/.mm`, `NDIRuntime.h/.mm` — Obj-C++ wrappers, no UIKit/AppKit deps
- `Recorder.swift` — AVAssetWriter is identical between platforms; only `recordingsDirectory()` changes (use `.documentDirectory` instead of `.moviesDirectory`)
- `ReceiverModel.swift` — minor tweaks (no AVSampleBufferDisplayLayer differences worth noting)

Replacements:
- `DisplayLayerHostView` — `NSViewRepresentable` → `UIViewRepresentable`
- `ReceiverView` — drop the resizable-window machinery, target single-screen iPad layout
- No `NDIStreamApp` Window scenes — just a `WindowGroup { ReceiverView() }`

## iOS-specific work

- **Local network permission.** `NSLocalNetworkUsageDescription` in Info.plist explaining what NDI does. Plus `NSBonjourServices` listing NDI's service types: `_ndi._tcp`, `_ndi-discovery._tcp` (verify against current NDI SDK docs at build time). Without these, discovery returns nothing silently.
- **NDI iOS SDK.** Static framework at `/Library/NDI SDK for Apple/lib/iOS/` — link statically, not dylib like macOS. No bundling/rpath dance needed but the build settings differ.
- **No backgrounding.** App goes to background → network drops. Acceptable for the use case (it stays foreground on a stand) but document it. Don't fight it with audio-mode tricks; Apple review will reject.
- **Files access for recordings.** Write to `.documentDirectory`, expose via `UIDocumentPickerViewController` or share sheet. Optionally enable `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` so recordings show up in the Files app under "NDIStream."
- **Orientation.** Landscape-only on iPad. Portrait makes no sense for a 16:9 video display.
- **Stage Manager / Split View.** Allow but don't optimize for it. Single full-screen view is the use case.

## Distribution

Three options, in order of friction:

1. **TestFlight** — best for "tools we use on set, share with crew." Up to 100 internal testers, 90-day install lifetime per build. No App Store review for internal testing. **Default choice.**
2. **App Store** — public-facing, requires review. Probably approvable (Vizrt's NDI HX Camera ships on the Store) but adds review friction and ongoing maintenance.
3. **Ad-hoc / dev-team install** — sideload via Xcode for specific devices. Fine for prototyping, painful for distribution.

## Open questions

- Does NDI's iOS SDK still ship as a static lib, or has it gone XCFramework? (Check SDK version at build time.)
- Multi-source view — would a 2×2 grid of small previews be useful (multi-cam village)? Probably yes, but separate spec.
- Audio receive — current macOS app skips audio entirely. For an iPad on set, getting audio out of a wired headphone jack (via USB-C adapter) for the off-camera actor would be a real win. Separate small task.

## Next implementation slice

1. Add an iOS/iPadOS app target with a landscape receiver UI and sample-buffer display layer.
2. Add audio monitoring and recording/share-sheet composition around the core callbacks.
3. Exercise a real Mac-to-iPad LiveKit room on LAN.
4. Add a mobile sender capture adapter only after choosing one explicit owner for both camera and microphone.

## Out of scope

- iPhone — screen is too small to be useful as a scene-partner display
- Sender on iOS — Mac does it better; revisit only if a specific use case appears
- PTZ controls, audio mixing, multi-source compositing, recording-to-Photos
