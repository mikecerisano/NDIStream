import AVFoundation
import Combine
import CoreVideo
import Foundation

private final class SenderFrameWatchdog {
    private let queue = DispatchQueue(label: "NDIStream.SenderFrameWatchdog", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastFrameAt = Date()
    private var stallCount = 0

    func start(onStall: @escaping (Int, TimeInterval) -> Void) {
        stop()
        lock.lock()
        lastFrameAt = Date()
        stallCount = 0
        lock.unlock()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let elapsed = Date().timeIntervalSince(self.lastFrameAt)
            if elapsed >= 3.0 {
                self.stallCount += 1
                let count = self.stallCount
                self.lastFrameAt = Date()
                self.lock.unlock()
                DebugLog.write("WARN sender frame watchdog stall count=\(count) elapsed=\(String(format: "%.2f", elapsed))")
                onStall(count, elapsed)
            } else {
                self.lock.unlock()
            }
        }
        timer = t
        t.resume()
        DebugLog.write("sender frame watchdog start")
    }

    func markFrame() {
        lock.lock()
        lastFrameAt = Date()
        lock.unlock()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        DebugLog.write("sender frame watchdog stop")
    }
}

private final class SenderFrameRepeater {
    private let queue = DispatchQueue(label: "NDIStream.SenderFrameRepeater", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastRealFrameAt = Date()
    private var isRepeating = false
    private var repeatCount = 0

    func start(sendRepeat: @escaping () -> Void) {
        stop()
        lock.lock()
        lastRealFrameAt = Date()
        isRepeating = false
        repeatCount = 0
        lock.unlock()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(67))
        t.setEventHandler { [weak self] in
            guard let self else { return }

            self.lock.lock()
            let elapsed = Date().timeIntervalSince(self.lastRealFrameAt)
            guard elapsed >= 0.5 else {
                self.lock.unlock()
                return
            }
            if !self.isRepeating {
                self.isRepeating = true
                self.repeatCount = 0
                DebugLog.write("sender frame repeater start elapsed=\(String(format: "%.2f", elapsed))")
            }
            self.repeatCount += 1
            let count = self.repeatCount
            self.lock.unlock()

            sendRepeat()
            if count == 1 || count % 30 == 0 {
                DebugLog.write("sender frame repeater sent count=\(count)")
            }
        }
        timer = t
        t.resume()
        DebugLog.write("sender frame repeater timer start")
    }

    func markRealFrame() {
        lock.lock()
        let wasRepeating = isRepeating
        let count = repeatCount
        isRepeating = false
        repeatCount = 0
        lastRealFrameAt = Date()
        lock.unlock()

        if wasRepeating {
            DebugLog.write("sender real frames resumed after repeats=\(count)")
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        DebugLog.write("sender frame repeater stop")
    }
}

@MainActor
final class BroadcastController: ObservableObject {
    enum Status: Equatable {
        case idle
        case live(width: Int, height: Int, fps: Int)
        case error(String)
    }

    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var availableAudioDevices: [AVCaptureDevice] = []
    @Published var selectedCameraID: String {
        didSet {
            UserDefaults.standard.set(selectedCameraID, forKey: "lastCameraID")
            if isBroadcasting, let dev = currentDevice() {
                do { try cameraManager.switchToDevice(dev, quality: quality, fps: targetFPS, pixelFormat: pixelFormat) }
                catch { status = .error(error.localizedDescription) }
            }
        }
    }
    @Published var selectedAudioDeviceID: String {
        didSet {
            UserDefaults.standard.set(selectedAudioDeviceID, forKey: "lastAudioDeviceID")
        }
    }
    @Published var audioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: "senderAudioEnabled")
        }
    }
    @Published var sourceName: String {
        didSet {
            UserDefaults.standard.set(sourceName, forKey: "lastSourceName")
            if isBroadcasting { restartSender() }
        }
    }
    @Published var targetFPS: Int {
        didSet {
            UserDefaults.standard.set(targetFPS, forKey: "targetFPS")
            if isBroadcasting { cameraManager.setFPS(targetFPS) }
        }
    }
    @Published var quality: QualityPreset {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: "quality")
            if isBroadcasting, let dev = currentDevice() {
                do { try cameraManager.switchToDevice(dev, quality: quality, fps: targetFPS, pixelFormat: pixelFormat) }
                catch { status = .error(error.localizedDescription) }
            }
        }
    }
    @Published var pixelFormat: CapturePixelFormat {
        didSet {
            UserDefaults.standard.set(pixelFormat.rawValue, forKey: "pixelFormat")
            cameraManager.setPixelFormat(pixelFormat)
        }
    }
    @Published var smoothPacing: Bool {
        didSet {
            if lowestLatency, smoothPacing {
                smoothPacing = false
                return
            }
            UserDefaults.standard.set(smoothPacing, forKey: "smoothPacing")
            if isBroadcasting { restartSender() }
        }
    }
    @Published var lowestLatency: Bool {
        didSet {
            UserDefaults.standard.set(lowestLatency, forKey: "lowestLatency")
            if lowestLatency, smoothPacing {
                smoothPacing = false
            }
            NDIRuntime.writeConfigLowestLatency(lowestLatency)
            let initialized = NDIRuntime.isInitialized()
            if initialized {
                lowestLatencyRelaunchRequired = lowestLatency != appliedLowestLatency
            } else {
                appliedLowestLatency = lowestLatency
                lowestLatencyRelaunchRequired = false
            }
            DebugLog.write("lowestLatency=\(lowestLatency) ndiInitialized=\(initialized) pendingRelaunch=\(lowestLatencyRelaunchRequired)")
        }
    }
    @Published var transport: LinkMode {
        didSet {
            UserDefaults.standard.set(transport.rawValue, forKey: "senderLinkMode")
            if isBroadcasting { restartSender() }
        }
    }
    @Published var lowestLatencyRelaunchRequired: Bool = false
    @Published var isBroadcasting: Bool = false
    @Published var isTransitioning: Bool = false
    @Published var status: Status = .idle
    @Published var slate: String {
        didSet { UserDefaults.standard.set(slate, forKey: "senderSlate") }
    }
    @Published var autoRecord: Bool {
        didSet { UserDefaults.standard.set(autoRecord, forKey: "senderAutoRecord") }
    }
    @Published var isLocked: Bool = false

    let linkConnection: LinkConnectionController

    let cameraManager = CameraManager()
    let recorder = Recorder(filenamePrefix: "Sender")
    private let linkMediaSource = LocalMediaSource()
    private let linkRecorderQueue = DispatchQueue(label: "StageGlassLink.BroadcastRecorder", qos: .userInteractive)
    private var linkRecorderSubscription: LocalMediaSource.Subscription?
    private var sender: VideoSender?
    private let senderLock = NSLock()
    private let frameWatchdog = SenderFrameWatchdog()
    private let frameRepeater = SenderFrameRepeater()
    private var appliedLowestLatency = false

    private func setSender(_ s: VideoSender?) {
        senderLock.lock()
        sender = s
        senderLock.unlock()
    }

    private func currentSender() -> VideoSender? {
        senderLock.lock()
        let s = sender
        senderLock.unlock()
        return s
    }

    /// The active sender (if broadcasting). Public reader so UI can read the
    /// underlying transport's `currentStats()`.
    var activeSender: VideoSender? { currentSender() }

    init(makeLinkSession: LinkMediaSessionFactory? = nil) {
        DebugLog.write("BroadcastController.init")
        self.linkConnection = LinkConnectionController(defaults: .standard,
                                                       keyPrefix: "sender",
                                                       defaultDisplayName: "Mac Camera",
                                                       makeSession: makeLinkSession)
        let cameras = CameraManager.availableDevices()
        self.availableCameras = cameras
        let audioDevices = CameraManager.availableAudioDevices()
        self.availableAudioDevices = audioDevices

        let saved = UserDefaults.standard.string(forKey: "lastCameraID")
        if let saved, cameras.contains(where: { $0.uniqueID == saved }) {
            self.selectedCameraID = saved
        } else if let facetime = cameras.first(where: { $0.localizedName.lowercased().contains("facetime") }) {
            self.selectedCameraID = facetime.uniqueID
        } else {
            self.selectedCameraID = cameras.first?.uniqueID ?? ""
        }

        let savedAudio = UserDefaults.standard.string(forKey: "lastAudioDeviceID")
        if let savedAudio, audioDevices.contains(where: { $0.uniqueID == savedAudio }) {
            self.selectedAudioDeviceID = savedAudio
        } else {
            self.selectedAudioDeviceID = audioDevices.first?.uniqueID ?? ""
        }
        self.audioEnabled = UserDefaults.standard.bool(forKey: "senderAudioEnabled")

        self.sourceName = UserDefaults.standard.string(forKey: "lastSourceName") ?? "Mac Camera"

        let savedFPS = UserDefaults.standard.integer(forKey: "targetFPS")
        self.targetFPS = (savedFPS == 30 || savedFPS == 60) ? savedFPS : 30

        let savedQuality = UserDefaults.standard.string(forKey: "quality").flatMap(QualityPreset.init(rawValue:))
        self.quality = savedQuality ?? .native

        let savedPixelFormat = UserDefaults.standard.string(forKey: "pixelFormat").flatMap(CapturePixelFormat.init(rawValue:))
        self.pixelFormat = savedPixelFormat ?? .bgra

        let savedLowestLatency = UserDefaults.standard.bool(forKey: "lowestLatency")
        self.lowestLatency = savedLowestLatency
        self.appliedLowestLatency = savedLowestLatency
        self.smoothPacing = savedLowestLatency ? false : UserDefaults.standard.bool(forKey: "smoothPacing")
        if savedLowestLatency {
            UserDefaults.standard.set(false, forKey: "smoothPacing")
        }
        self.slate = UserDefaults.standard.string(forKey: "senderSlate") ?? ""
        self.autoRecord = UserDefaults.standard.bool(forKey: "senderAutoRecord")
        self.transport = LinkMode.restored(from: .standard,
                                           key: "senderLinkMode",
                                           legacyKey: "senderTransport")
        cameraManager.setPixelFormat(pixelFormat)
        DebugLog.write("BroadcastController selectedCameraID=\(selectedCameraID) selectedAudioDeviceID=\(selectedAudioDeviceID) audioEnabled=\(audioEnabled) sourceName=\(sourceName) fps=\(targetFPS) quality=\(quality.rawValue) pixelFormat=\(pixelFormat.rawValue) smoothPacing=\(smoothPacing) lowestLatency=\(lowestLatency)")
    }

    func currentDevice() -> AVCaptureDevice? {
        availableCameras.first(where: { $0.uniqueID == selectedCameraID })
    }

    func currentAudioDevice() -> AVCaptureDevice? {
        availableAudioDevices.first(where: { $0.uniqueID == selectedAudioDeviceID })
    }

    func refreshCameras() {
        availableCameras = CameraManager.availableDevices()
        if !availableCameras.contains(where: { $0.uniqueID == selectedCameraID }) {
            selectedCameraID = availableCameras.first?.uniqueID ?? ""
        }
        availableAudioDevices = CameraManager.availableAudioDevices()
        if !availableAudioDevices.contains(where: { $0.uniqueID == selectedAudioDeviceID }) {
            selectedAudioDeviceID = availableAudioDevices.first?.uniqueID ?? ""
        }
        DebugLog.write("refreshCameras count=\(availableCameras.count) selected=\(selectedCameraID) audioCount=\(availableAudioDevices.count) selectedAudio=\(selectedAudioDeviceID)")
    }

    func start() {
        DebugLog.write("BroadcastController.start requested isBroadcasting=\(isBroadcasting) isTransitioning=\(isTransitioning)")
        guard !isBroadcasting, !isTransitioning else { return }
        isTransitioning = true

        Task {
            if self.transport == .link, !self.linkConnection.isJoined {
                self.status = .error("Join a Link session before starting the camera.")
                self.isTransitioning = false
                return
            }
            let granted = await CameraManager.requestAccess()
            guard granted else {
                DebugLog.write("ERROR camera permission denied")
                self.status = .error("Camera permission denied. Enable in System Settings → Privacy & Security → Camera.")
                self.isTransitioning = false
                return
            }
            guard let device = self.currentDevice() else {
                DebugLog.write("ERROR no currentDevice selectedCameraID=\(self.selectedCameraID) available=\(self.availableCameras.map { $0.localizedName })")
                self.status = .error("No camera selected.")
                self.isTransitioning = false
                return
            }

            let audioDevice = self.audioEnabled ? self.currentAudioDevice() : nil
            if self.audioEnabled {
                let audioGranted = await CameraManager.requestAudioAccess()
                guard audioGranted else {
                    DebugLog.write("ERROR microphone permission denied")
                    self.status = .error("Microphone permission denied. Enable in System Settings → Privacy & Security → Microphone.")
                    self.isTransitioning = false
                    return
                }
                guard audioDevice != nil else {
                    DebugLog.write("ERROR audio enabled but no microphone selected")
                    self.status = .error("No microphone selected.")
                    self.isTransitioning = false
                    return
                }
            }

            do {
                try self.cameraManager.switchToDevice(device, quality: self.quality, fps: self.targetFPS, pixelFormat: self.pixelFormat)
                try self.cameraManager.configureAudio(device: audioDevice)
            } catch {
                DebugLog.write("ERROR switchToDevice failed \(error.localizedDescription)")
                self.status = .error(error.localizedDescription)
                self.isTransitioning = false
                return
            }

            let fpsN = Int32(self.targetFPS * 1000)
            let fpsD: Int32 = 1000
            let rec = self.recorder
            let watchdog = self.frameWatchdog
            let repeater = self.frameRepeater
            var sentFrameCount = 0
            switch self.transport {
            case .link:
                do {
                    try await self.linkConnection.publishCamera(self.linkMediaSource)
                    try await self.linkConnection.setMicrophoneEnabled(self.audioEnabled)
                } catch {
                    DebugLog.write("ERROR Link publisher start failed \(error.localizedDescription)")
                    self.status = .error(error.localizedDescription)
                    self.isTransitioning = false
                    return
                }
                self.linkRecorderSubscription = self.linkMediaSource.subscribe(
                    queue: self.linkRecorderQueue,
                    onVideoFrame: { [weak self] pixelBuffer, pts in
                        guard let self else { return }
                        watchdog.markFrame()
                        self.observeDimensionsIfNeeded(pixelBuffer)
                        rec.append(pixelBuffer: pixelBuffer, pts: pts)
                    },
                    onAudioSampleBuffer: { sampleBuffer in
                        rec.appendAudio(sampleBuffer: sampleBuffer)
                    }
                )
                self.linkMediaSource.attach(to: self.cameraManager)
                DebugLog.write("Link publisher ready sdkMicrophone=\(self.audioEnabled) localRecorderAudio=\(self.audioEnabled)")

            case .ndi:
                guard let s = TransportFactory.makeSender(mode: self.transport,
                                                          sourceName: self.sourceName,
                                                          clockVideo: self.smoothPacing) else {
                    DebugLog.write("ERROR sender create failed transport=\(self.transport.rawValue) sourceName=\(self.sourceName)")
                    self.status = .error("Failed to create \(self.transport.rawValue) sender.")
                    self.isTransitioning = false
                    return
                }
                DebugLog.write("sender created transport=\(self.transport.rawValue) sourceName=\(self.sourceName) clockVideo=\(self.smoothPacing)")
                self.setSender(s)
                if self.audioEnabled {
                    self.cameraManager.onAudioSampleBuffer = { [weak self] sampleBuffer in
                        guard let self else { return }
                        self.currentSender()?.sendAudio(sampleBuffer)
                        self.recorder.appendAudio(sampleBuffer: sampleBuffer)
                    }
                    DebugLog.write("sender audio enabled device=\(audioDevice?.localizedName ?? "unknown")")
                } else {
                    self.cameraManager.onAudioSampleBuffer = nil
                    DebugLog.write("sender audio disabled")
                }
                self.cameraManager.onFrame = { [weak self] pb, pts in
                    guard let self else { return }
                    watchdog.markFrame()
                    repeater.markRealFrame()
                    if let snd = self.currentSender() {
                        sentFrameCount += 1
                        if sentFrameCount == 1 || sentFrameCount % 60 == 0 {
                            DebugLog.write("sender onFrame \(sentFrameCount) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) pf=\(CVPixelBufferGetPixelFormatType(pb)) pts=\(pts.seconds)")
                        }
                        snd.send(pixelBuffer: pb, frameRateN: fpsN, frameRateD: fpsD)
                    } else {
                        DebugLog.write("WARN onFrame with nil sender")
                    }
                    self.observeDimensionsIfNeeded(pb)
                    rec.append(pixelBuffer: pb, pts: pts)
                }
                self.frameRepeater.start { [weak self] in
                    guard let self, let snd = self.currentSender() else { return }
                    snd.repeatLastFrame(frameRateN: fpsN, frameRateD: fpsD)
                }
            }

            self.frameWatchdog.start { count, elapsed in
                DebugLog.write("sender watchdog stall observed count=\(count) elapsed=\(String(format: "%.2f", elapsed)); capture session left running")
            }
            self.cameraManager.start()
            self.isBroadcasting = true
            ActivityKeeper.begin("broadcast")
            self.isTransitioning = false
            self.status = .live(width: 0, height: 0, fps: self.targetFPS)
            if self.autoRecord, !self.recorder.isRecording {
                DebugLog.write("auto-record start (sender)")
                self.recorder.start(slate: self.slate, includeAudio: self.audioEnabled)
            }
            DebugLog.write("BroadcastController.start completed")
        }
    }

    func stop() {
        DebugLog.write("BroadcastController.stop requested")
        guard isBroadcasting, !isTransitioning else { return }
        isTransitioning = true
        if recorder.isRecording { recorder.stop() }
        frameRepeater.stop()
        frameWatchdog.stop()
        linkMediaSource.detach(from: cameraManager)
        linkRecorderSubscription?.cancel()
        linkRecorderSubscription = nil
        if transport == .link {
            Task { [linkConnection] in
                try? await linkConnection.setMicrophoneEnabled(false)
            }
        }
        cameraManager.onAudioSampleBuffer = nil
        cameraManager.onFrame = nil
        cameraManager.stop()
        let outgoing = currentSender()
        setSender(nil)
        outgoing?.stop()
        isBroadcasting = false
        ActivityKeeper.end("broadcast")
        status = .idle
        isTransitioning = false
        DebugLog.write("BroadcastController.stop completed")
    }

    /// Deterministic process-lifecycle teardown. Unlike the ordinary Stop button,
    /// this also leaves a joined-but-idle Link session before AppKit exits.
    func shutdown() async {
        if isBroadcasting { stop() }
        await recorder.stopAndWait()
        frameRepeater.stop()
        frameWatchdog.stop()
        linkMediaSource.detach(from: cameraManager)
        linkRecorderSubscription?.cancel()
        linkRecorderSubscription = nil
        cameraManager.onAudioSampleBuffer = nil
        cameraManager.onFrame = nil
        cameraManager.stop()
        let outgoing = currentSender()
        setSender(nil)
        outgoing?.stop()
        await linkConnection.leave()
        ActivityKeeper.end("broadcast")
    }

    private func restartSender() {
        DebugLog.write("restartSender")
        guard transport == .ndi else {
            DebugLog.write("restartSender ignored for Link; the joined session owns publication")
            return
        }
        let outgoing = currentSender()
        setSender(nil)
        outgoing?.stop()
        let fresh = TransportFactory.makeSender(mode: transport,
                                                sourceName: sourceName, clockVideo: smoothPacing)
        setSender(fresh)
        if fresh == nil {
            DebugLog.write("ERROR restartSender failed")
            status = .error("Failed to recreate \(transport.rawValue) sender.")
        } else {
            DebugLog.write("restartSender succeeded")
        }
    }

    private var lastReportedDims: (Int, Int) = (0, 0)
    private func observeDimensionsIfNeeded(_ pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        if (w, h) != lastReportedDims {
            lastReportedDims = (w, h)
            DebugLog.write("observeDimensions \(w)x\(h)")
            let fps = self.targetFPS
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isBroadcasting else { return }
                self.status = .live(width: w, height: h, fps: fps)
            }
        }
    }
}
