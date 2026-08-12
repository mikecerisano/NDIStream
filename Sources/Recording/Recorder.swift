import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

final class Recorder: ObservableObject, @unchecked Sendable {
    @MainActor @Published private(set) var isRecording = false
    @MainActor @Published private(set) var elapsed: TimeInterval = 0
    @MainActor @Published private(set) var lastError: String? = nil

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let writeQueue = DispatchQueue(label: "NDIStream.Recorder.Write")
    private let finalizationGroup = DispatchGroup()
    private var startPTS: CMTime?
    private var pendingVideo: PendingVideo?
    private var pendingAudioFormat: AudioTrackFormat?
    private var wantsAudio = false
    private var audioWaitFallbackScheduled = false
    private var syntheticAudioPTS: CMTime?
    private var writerActive = false
    private var pendingSlate: String = ""
    private let writerActiveLock = NSLock()

    @MainActor private var timer: Timer?
    @MainActor private var startWallTime: Date?

    private let prefix: String

    init(filenamePrefix: String) { self.prefix = filenamePrefix }

    private struct AudioTrackFormat {
        let sampleRate: Int
        let channels: Int
    }

    private struct PendingVideo {
        let pixelBuffer: CVPixelBuffer
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let pts: CMTime
    }

    private func setWriterActive(_ active: Bool) {
        writerActiveLock.lock()
        writerActive = active
        writerActiveLock.unlock()
    }

    private func isWriterActive() -> Bool {
        writerActiveLock.lock()
        let v = writerActive
        writerActiveLock.unlock()
        return v
    }

    @MainActor
    func start(slate: String = "", includeAudio: Bool = false) {
        guard !isRecording else { return }
        isRecording = true
        elapsed = 0
        startWallTime = Date()
        lastError = nil
        setWriterActive(true)
        let capturedSlate = slate
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writer = nil
            self.input = nil
            self.audioInput = nil
            self.adaptor = nil
            self.startPTS = nil
            self.releasePendingVideo()
            self.pendingAudioFormat = nil
            self.wantsAudio = includeAudio
            self.audioWaitFallbackScheduled = false
            self.syntheticAudioPTS = nil
            self.pendingSlate = capturedSlate
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startWallTime else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    func append(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard isWriterActive() else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let pf = CVPixelBufferGetPixelFormatType(pixelBuffer)
        writeQueue.async { [weak self] in
            guard let self, self.isWriterActive() else { return }
            if self.writer == nil {
                if self.wantsAudio, self.pendingAudioFormat == nil {
                    self.storePendingVideoIfNeeded(pixelBuffer: pixelBuffer, width: w, height: h, pixelFormat: pf, pts: pts)
                    self.scheduleAudioWaitFallbackIfNeeded()
                    return
                }
                self.setupWriter(width: w, height: h, pixelFormat: pf, firstPTS: pts, audioFormat: self.pendingAudioFormat)
            }
            guard let writer = self.writer,
                  let input = self.input,
                  let adaptor = self.adaptor else { return }
            if writer.status == .failed {
                self.surface(error: writer.error?.localizedDescription ?? "Writer failed")
                return
            }
            guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                let msg = writer.error?.localizedDescription ?? "Append failed (status \(writer.status.rawValue))"
                self.surface(error: msg)
            }
        }
    }

    func appendAudio(sampleBuffer: CMSampleBuffer) {
        guard isWriterActive() else { return }
        let format = Self.audioFormat(from: sampleBuffer)
        writeQueue.async { [weak self] in
            guard let self, self.isWriterActive() else { return }
            if self.pendingAudioFormat == nil, let format {
                self.pendingAudioFormat = format
                self.setupWriterFromPendingVideoIfPossible()
            }
            guard let writer = self.writer,
                  let audioInput = self.audioInput else { return }
            if writer.status == .failed {
                self.surface(error: writer.error?.localizedDescription ?? "Writer failed")
                return
            }
            guard writer.status == .writing, audioInput.isReadyForMoreMediaData else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let start = self.startPTS, pts.isValid, CMTimeCompare(pts, start) < 0 {
                return
            }
            if !audioInput.append(sampleBuffer) {
                let msg = writer.error?.localizedDescription ?? "Audio append failed (status \(writer.status.rawValue))"
                self.surface(error: msg)
            }
        }
    }

    func appendPlanarFloatAudio(samples: UnsafePointer<Float>,
                                sampleRate: Int32,
                                channels: Int32,
                                samplesPerChannel: Int32,
                                channelStrideBytes: Int32) {
        guard isWriterActive(),
              sampleRate > 0,
              channels > 0,
              samplesPerChannel > 0 else { return }

        let channelCount = Int(channels)
        let frameCount = Int(samplesPerChannel)
        let strideFloats = Int(channelStrideBytes) / MemoryLayout<Float>.stride
        guard strideFloats >= frameCount else { return }

        var interleaved = [Float](repeating: 0, count: channelCount * frameCount)
        for ch in 0..<channelCount {
            let src = samples.advanced(by: ch * strideFloats)
            for frame in 0..<frameCount {
                interleaved[frame * channelCount + ch] = src[frame]
            }
        }

        let format = AudioTrackFormat(sampleRate: Int(sampleRate), channels: channelCount)
        writeQueue.async { [weak self] in
            guard let self, self.isWriterActive() else { return }
            if self.pendingAudioFormat == nil {
                self.pendingAudioFormat = format
                self.setupWriterFromPendingVideoIfPossible()
            }
            guard let writer = self.writer,
                  let audioInput = self.audioInput else { return }
            if writer.status == .failed {
                self.surface(error: writer.error?.localizedDescription ?? "Writer failed")
                return
            }
            guard writer.status == .writing, audioInput.isReadyForMoreMediaData else { return }
            let pts = self.nextSyntheticAudioPTS(sampleRate: format.sampleRate, sampleCount: frameCount)
            guard let sampleBuffer = Self.makeInterleavedFloatSampleBuffer(samples: interleaved,
                                                                           sampleRate: format.sampleRate,
                                                                           channels: format.channels,
                                                                           pts: pts) else {
                self.surface(error: "Could not create audio sample buffer")
                return
            }
            if !audioInput.append(sampleBuffer) {
                let msg = writer.error?.localizedDescription ?? "Audio append failed (status \(writer.status.rawValue))"
                self.surface(error: msg)
            }
        }
    }

    @MainActor
    func stop() {
        guard isRecording else { return }
        isRecording = false
        setWriterActive(false)
        timer?.invalidate()
        timer = nil
        let finalizationGroup = finalizationGroup
        finalizationGroup.enter()
        writeQueue.async { [weak self] in
            guard let self else {
                finalizationGroup.leave()
                return
            }
            guard let w = self.writer else {
                self.input = nil
                self.audioInput = nil
                self.adaptor = nil
                self.startPTS = nil
                self.releasePendingVideo()
                self.pendingAudioFormat = nil
                self.syntheticAudioPTS = nil
                self.finalizationGroup.leave()
                return
            }
            self.input?.markAsFinished()
            self.audioInput?.markAsFinished()
            w.finishWriting {
                if w.status == .failed {
                    let msg = w.error?.localizedDescription ?? "Finalize failed"
                    Task { @MainActor in self.lastError = msg }
                }
                self.finalizationGroup.leave()
            }
            self.writer = nil
            self.input = nil
            self.audioInput = nil
            self.adaptor = nil
            self.startPTS = nil
            self.releasePendingVideo()
            self.pendingAudioFormat = nil
            self.syntheticAudioPTS = nil
        }
    }

    @MainActor
    func stopAndWait() async {
        stop()
        await withCheckedContinuation { continuation in
            finalizationGroup.notify(queue: .main) { continuation.resume() }
        }
    }

    private func setupWriter(width: Int, height: Int, pixelFormat: OSType, firstPTS: CMTime, audioFormat: AudioTrackFormat?) {
        let url = Recorder.makeURL(prefix: prefix, slate: pendingSlate)
        do {
            try Recorder.ensureDirectory()
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Self.bitrate(width: width, height: height),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: 60
                ]
            ]
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            i.expectsMediaDataInRealTime = true
            let a = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: i,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
            )
            guard w.canAdd(i) else {
                surface(error: "Cannot add video input for \(width)×\(height)")
                return
            }
            w.add(i)

            var ai: AVAssetWriterInput?
            if let audioFormat {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: audioFormat.sampleRate,
                    AVNumberOfChannelsKey: audioFormat.channels,
                    AVEncoderBitRateKey: max(64_000, min(192_000, audioFormat.channels * 96_000))
                ]
                let candidate = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                candidate.expectsMediaDataInRealTime = true
                guard w.canAdd(candidate) else {
                    surface(error: "Cannot add audio input")
                    return
                }
                w.add(candidate)
                ai = candidate
            }

            guard w.startWriting() else {
                surface(error: w.error?.localizedDescription ?? "startWriting failed")
                return
            }
            w.startSession(atSourceTime: firstPTS)
            self.writer = w
            self.input = i
            self.audioInput = ai
            self.adaptor = a
            self.startPTS = firstPTS
            self.syntheticAudioPTS = firstPTS
        } catch {
            surface(error: error.localizedDescription)
        }
    }

    private func storePendingVideoIfNeeded(pixelBuffer: CVPixelBuffer,
                                           width: Int,
                                           height: Int,
                                           pixelFormat: OSType,
                                           pts: CMTime) {
        guard pendingVideo == nil else { return }
        pendingVideo = PendingVideo(pixelBuffer: pixelBuffer,
                                    width: width,
                                    height: height,
                                    pixelFormat: pixelFormat,
                                    pts: pts)
    }

    private func setupWriterFromPendingVideoIfPossible() {
        guard writer == nil, let pendingVideo else { return }
        setupWriter(width: pendingVideo.width,
                    height: pendingVideo.height,
                    pixelFormat: pendingVideo.pixelFormat,
                    firstPTS: pendingVideo.pts,
                    audioFormat: pendingAudioFormat)
        appendPendingVideoIfPossible()
    }

    private func appendPendingVideoIfPossible() {
        guard let pendingVideo,
              let writer,
              let input,
              let adaptor,
              writer.status == .writing,
              input.isReadyForMoreMediaData else { return }
        if !adaptor.append(pendingVideo.pixelBuffer, withPresentationTime: pendingVideo.pts) {
            let msg = writer.error?.localizedDescription ?? "Video append failed (status \(writer.status.rawValue))"
            surface(error: msg)
        }
        releasePendingVideo()
    }

    private func releasePendingVideo() {
        pendingVideo = nil
    }

    private func scheduleAudioWaitFallbackIfNeeded() {
        guard !audioWaitFallbackScheduled else { return }
        audioWaitFallbackScheduled = true
        writeQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self,
                  self.isWriterActive(),
                  self.writer == nil,
                  let pendingVideo = self.pendingVideo else { return }
            self.setupWriter(width: pendingVideo.width,
                             height: pendingVideo.height,
                             pixelFormat: pendingVideo.pixelFormat,
                             firstPTS: pendingVideo.pts,
                             audioFormat: nil)
            self.appendPendingVideoIfPossible()
            Task { @MainActor in
                self.lastError = "No audio in first second — recording video only"
            }
        }
    }

    private func nextSyntheticAudioPTS(sampleRate: Int, sampleCount: Int) -> CMTime {
        let pts = syntheticAudioPTS ?? startPTS ?? .zero
        let duration = CMTime(value: CMTimeValue(sampleCount), timescale: CMTimeScale(sampleRate))
        syntheticAudioPTS = CMTimeAdd(pts, duration)
        return pts
    }

    private func surface(error message: String) {
        setWriterActive(false)
        if let w = writer {
            w.cancelWriting()
        }
        writer = nil
        input = nil
        audioInput = nil
        adaptor = nil
        startPTS = nil
        releasePendingVideo()
        pendingAudioFormat = nil
        syntheticAudioPTS = nil
        Task { @MainActor in
            self.lastError = message
            self.isRecording = false
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    private static func bitrate(width: Int, height: Int) -> Int {
        let pixels = width * height
        if pixels >= 1920 * 1080 { return 10_000_000 }
        if pixels >= 1280 * 720  { return 5_000_000 }
        return 3_000_000
    }

    private static func audioFormat(from sampleBuffer: CMSampleBuffer) -> AudioTrackFormat? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return nil }
        let sampleRate = Int(asbd.pointee.mSampleRate.rounded())
        let channels = Int(asbd.pointee.mChannelsPerFrame)
        guard sampleRate > 0, channels > 0 else { return nil }
        return AudioTrackFormat(sampleRate: sampleRate, channels: channels)
    }

    private static func makeInterleavedFloatSampleBuffer(samples: [Float],
                                                         sampleRate: Int,
                                                         channels: Int,
                                                         pts: CMTime) -> CMSampleBuffer? {
        guard sampleRate > 0, channels > 0, !samples.isEmpty else { return nil }
        let frameCount = samples.count / channels
        guard frameCount > 0 else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * MemoryLayout<Float>.stride),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * MemoryLayout<Float>.stride),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.stride * 8),
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: &asbd,
                                             layoutSize: 0,
                                             layout: nil,
                                             magicCookieSize: 0,
                                             magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { return nil }

        let byteCount = samples.count * MemoryLayout<Float>.stride
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: byteCount,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: byteCount,
                                                 flags: 0,
                                                 blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return nil }

        let copied = samples.withUnsafeBytes { rawBuffer in
            CMBlockBufferReplaceDataBytes(with: rawBuffer.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: byteCount)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                   dataBuffer: blockBuffer,
                                   dataReady: true,
                                   makeDataReadyCallback: nil,
                                   refcon: nil,
                                   formatDescription: formatDescription,
                                   sampleCount: frameCount,
                                   sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil,
                                   sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    static func recordingsDirectory() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("NDIStream", isDirectory: true)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: recordingsDirectory(),
                                                withIntermediateDirectories: true)
    }

    static func makeURL(prefix: String, slate: String = "") -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let cleanSlate = sanitizeSlate(slate)
        let middle = cleanSlate.isEmpty ? "" : "-\(cleanSlate)"
        let name = "\(prefix)\(middle)-\(df.string(from: Date())).mov"
        return recordingsDirectory().appendingPathComponent(name)
    }

    static func sanitizeSlate(_ slate: String) -> String {
        let illegal: Set<Character> = ["/", "\\", ":", "<", ">", "|", "?", "*", "\"", "\0", "\n", "\r", "\t"]
        let filtered = String(slate.filter { !illegal.contains($0) })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func revealRecordingsFolder() {
        try? ensureDirectory()
        NSWorkspace.shared.open(recordingsDirectory())
    }
}
