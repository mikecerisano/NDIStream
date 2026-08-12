import AppKit
import AVFoundation
import Combine
import CoreMedia
import Foundation

@MainActor
final class ReceiverModel: NSObject, ObservableObject {
    enum Tally: Equatable { case idle, waiting, live, reconnecting }

    @Published var availableSources: [FoundSource] = []
    @Published var selectedSourceName: String = ""
    @Published var selectedTransport: LinkMode {
        didSet {
            UserDefaults.standard.set(selectedTransport.rawValue, forKey: "receiverLinkMode")
            // When transport changes, re-filter the visible source list and clear stale selection.
            refilterAndPublish()
            if !availableSources.contains(where: { $0.name == selectedSourceName }) {
                selectedSourceName = availableSources.first?.name ?? ""
            }
        }
    }
    @Published var isConnected: Bool = false
    @Published var statusLine: String = "No source selected"
    @Published var lastFormat: FrameFormat? = nil
    @Published var tally: Tally = .idle
    @Published var slate: String = "" {
        didSet { UserDefaults.standard.set(slate, forKey: "receiverSlate") }
    }
    @Published var autoRecord: Bool = false {
        didSet { UserDefaults.standard.set(autoRecord, forKey: "receiverAutoRecord") }
    }
    @Published var audioEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: "receiverAudioEnabled")
            audioPlayer.setMuted(!audioEnabled)
        }
    }
    @Published var isLocked: Bool = false

    let linkConnection: LinkConnectionController

    struct FrameFormat: Equatable {
        let width: Int
        let height: Int
        let fps: Int
        let fourCC: String
    }

    let displayLayer = AVSampleBufferDisplayLayer()
    nonisolated let recorder = Recorder(filenamePrefix: "Receiver")
    nonisolated let audioPlayer = AudioPlayer()

    /// All finders running concurrently, one per transport. Their callbacks
    /// merge into `allSources`; `availableSources` is the filtered view.
    private let finders: [SourceFinder]
    /// Merged sources from all finders, keyed by `"<transport>::<name>"`.
    private var allSources: [String: FoundSource] = [:]
    private var receiver: VideoReceiver?
    /// The active receiver (if connected). Public reader so UI can read the
    /// underlying transport's `currentStats()`.
    var activeReceiver: VideoReceiver? { receiver }
    private var receivedFrameCount = 0
    private var hasPerformedInitialAutoselect = false

    init(makeLinkSession: LinkMediaSessionFactory? = nil) {
        DebugLog.write("ReceiverModel.init")
        self.linkConnection = LinkConnectionController(defaults: .standard,
                                                       keyPrefix: "receiver",
                                                       defaultDisplayName: "Mac Receiver",
                                                       makeSession: makeLinkSession)
        self.finders = TransportFactory.makeFinders()
        // Default to .ndi on first launch, restore last-used otherwise (per spec §"UI changes").
        let savedTransport = LinkMode.restored(from: .standard,
                                               key: "receiverLinkMode",
                                               legacyKey: "receiverTransport")
        self.selectedTransport = savedTransport
        super.init()

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor

        if let saved = UserDefaults.standard.string(forKey: "lastReceiverSource") {
            selectedSourceName = saved
        }
        self.slate = UserDefaults.standard.string(forKey: "receiverSlate") ?? ""
        self.autoRecord = UserDefaults.standard.bool(forKey: "receiverAutoRecord")
        self.audioEnabled = UserDefaults.standard.bool(forKey: "receiverAudioEnabled")
        audioPlayer.setMuted(!audioEnabled)

        // Wire every finder's callback to merge into allSources.
        for finder in finders {
            finder.onSourcesChanged = { [weak self] sources in
                guard let self else { return }
                Task { @MainActor in
                    self.ingest(sources: sources)
                }
            }
            for src in finder.currentSources() {
                let key = "\(src.transport.rawValue)::\(src.name)"
                allSources[key] = src
            }
        }
        refilterAndPublish()
    }

    /// Merge a finder's current sources into the global map. Sources from other
    /// transports are untouched. Triggers a refilter + autoselect pass.
    private func ingest(sources: [FoundSource]) {
        // Remove stale entries for the transports represented in this callback,
        // then re-insert.
        let touchedTransports = Set(sources.map(\.transport))
        // Snapshot keys before mutating — iterating `allSources.keys` while
        // calling `removeValue(forKey:)` is undefined behavior in Swift.
        let staleKeys = allSources.compactMap { (key, value) in
            touchedTransports.contains(value.transport) ? key : nil
        }
        for key in staleKeys {
            allSources.removeValue(forKey: key)
        }
        for src in sources {
            allSources["\(src.transport.rawValue)::\(src.name)"] = src
        }
        refilterAndPublish()

        if !hasPerformedInitialAutoselect, !availableSources.isEmpty, !isConnected {
            hasPerformedInitialAutoselect = true
            let savedMatches = availableSources.contains(where: { $0.name == selectedSourceName })
            if !savedMatches, let first = availableSources.first {
                let was = selectedSourceName
                selectedSourceName = first.name
                DebugLog.write("receiver auto-selected source=\(first.name) (saved='\(was)') transport=\(selectedTransport.rawValue)")
            }
        }
    }

    /// Publish the subset of `allSources` matching `selectedTransport`, sorted.
    private func refilterAndPublish() {
        let filtered = allSources.values
            .filter { selectedTransport == .ndi && $0.transport == .ndi }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        availableSources = filtered
        DebugLog.write("receiver sources refilter transport=\(selectedTransport.rawValue) count=\(filtered.count) names=\(filtered.map { $0.name })")
    }

    func connect() {
        DebugLog.write("receiver connect requested selected=\(selectedSourceName) available=\(availableSources.map { $0.name })")
        guard !isConnected else { return }
        let name = selectedSourceName
        guard !name.isEmpty else {
            statusLine = "No source selected"
            return
        }
        guard let source = availableSources.first(where: { $0.name == name }) else {
            DebugLog.write("ERROR receiver source not online name=\(name)")
            statusLine = "Source '\(name)' not currently online"
            return
        }

        UserDefaults.standard.set(name, forKey: "lastReceiverSource")

        guard let r = TransportFactory.makeReceiver(for: source) else {
            DebugLog.write("ERROR receiver create failed name=\(source.name) address=\(source.address) transport=\(source.transport.rawValue)")
            statusLine = "Failed to create receiver"
            return
        }
        r.delegate = self
        receiver = r
        isConnected = true
        tally = .waiting
        ActivityKeeper.begin("receiver")
        statusLine = "Connecting to \(name)…"
        lastFormat = nil
        receivedFrameCount = 0
        DebugLog.write("receiver created name=\(source.name) address=\(source.address)")
        if autoRecord, !recorder.isRecording {
            DebugLog.write("auto-record start (receiver)")
            recorder.start(slate: slate, includeAudio: true)
        }
    }

    func disconnect() {
        DebugLog.write("receiver disconnect requested")
        guard isConnected || receiver != nil else { return }
        if recorder.isRecording { recorder.stop() }
        receiver?.delegate = nil
        receiver?.stop()
        receiver = nil
        isConnected = false
        tally = .idle
        audioPlayer.stop()
        ActivityKeeper.end("receiver")
        displayLayer.flushAndRemoveImage()
        statusLine = "Disconnected"
        lastFormat = nil
        DebugLog.write("receiver disconnected")
    }
}

extension ReceiverModel: VideoReceiverDelegate {
    nonisolated func videoReceiverDidReceive(sampleBuffer: CMSampleBuffer,
                                        width: Int32,
                                        height: Int32,
                                        frameRateN: Int32,
                                        frameRateD: Int32,
                                        fourCC: UInt32) {
        let retained = sampleBuffer
        let w = Int(width)
        let h = Int(height)
        let frN = Int(frameRateN)
        let frD = Int(frameRateD)
        let cc = fourCC
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            recorder.append(pixelBuffer: pb, pts: pts)
        }
        Task { @MainActor in
            self.enqueueSampleBuffer(retained, width: w, height: h, frameRateN: frN, frameRateD: frD, fourCC: cc)
        }
    }

    nonisolated func videoReceiverDidDisconnect() {
        Task { @MainActor in
            self.handleRemoteDisconnect()
        }
    }

    nonisolated func videoReceiverDidStall(forSeconds seconds: Int) {
        Task { @MainActor in
            guard self.isConnected else { return }
            self.statusLine = "Reconnecting (\(seconds)s)…"
            self.tally = .reconnecting
        }
    }

    nonisolated func videoReceiverDidResume() {
        Task { @MainActor in
            guard self.isConnected else { return }
            self.statusLine = "Reconnected"
            self.tally = .live
        }
    }

    nonisolated func videoReceiverDidReceiveAudio(samples: UnsafePointer<Float>,
                                              sampleRate: Int32,
                                              channels: Int32,
                                              samplesPerChannel: Int32,
                                              channelStrideBytes: Int32) {
        recorder.appendPlanarFloatAudio(samples: samples,
                                        sampleRate: sampleRate,
                                        channels: channels,
                                        samplesPerChannel: samplesPerChannel,
                                        channelStrideBytes: channelStrideBytes)
        audioPlayer.schedule(samples: samples,
                             sampleRate: sampleRate,
                             channels: channels,
                             samplesPerChannel: samplesPerChannel,
                             channelStrideBytes: channelStrideBytes)
    }

    private func enqueueSampleBuffer(_ sb: CMSampleBuffer,
                                     width: Int,
                                     height: Int,
                                     frameRateN: Int,
                                     frameRateD: Int,
                                     fourCC: UInt32) {
        receivedFrameCount += 1
        if displayLayer.status == .failed {
            DebugLog.write("WARN receiver displayLayer failed; flushing error=\(String(describing: displayLayer.error))")
            displayLayer.flush()
        }
        if !displayLayer.isReadyForMoreMediaData {
            DebugLog.write("WARN receiver displayLayer backpressure; flushing queued frames")
            displayLayer.flush()
        }
        displayLayer.enqueue(sb)

        let fps: Int
        if frameRateD > 0 {
            fps = Int((Double(frameRateN) / Double(frameRateD)).rounded())
        } else {
            fps = 0
        }
        let fourCCStr = Self.fourCCString(fourCC)
        let fmt = FrameFormat(width: width, height: height, fps: fps, fourCC: fourCCStr)
        if receivedFrameCount == 1 || receivedFrameCount % 60 == 0 {
            DebugLog.write("receiver frame \(receivedFrameCount) \(width)x\(height) fps=\(fps) fourCC=\(fourCCStr) displayStatus=\(displayLayer.status.rawValue)")
        }
        if tally != .live { tally = .live }
        if lastFormat != fmt {
            lastFormat = fmt
            statusLine = "\(width)×\(height) @ \(fps) • \(fourCCStr)"
            DebugLog.write("receiver format \(statusLine)")
        }
    }

    private func handleRemoteDisconnect() {
        DebugLog.write("WARN receiver remote disconnect")
        if recorder.isRecording { recorder.stop() }
        receiver?.delegate = nil
        receiver?.stop()
        receiver = nil
        isConnected = false
        tally = .idle
        audioPlayer.stop()
        ActivityKeeper.end("receiver")
        displayLayer.flushAndRemoveImage()
        statusLine = "Source offline"
        lastFormat = nil
    }

    private static func fourCCString(_ cc: UInt32) -> String {
        let b0 = UInt8((cc >> 0) & 0xff)
        let b1 = UInt8((cc >> 8) & 0xff)
        let b2 = UInt8((cc >> 16) & 0xff)
        let b3 = UInt8((cc >> 24) & 0xff)
        let bytes: [UInt8] = [b0, b1, b2, b3]
        let str = String(bytes: bytes, encoding: .ascii) ?? "????"
        return str
    }
}
