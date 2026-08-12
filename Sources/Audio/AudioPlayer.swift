import AVFoundation
import CoreMedia
import Foundation

final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var currentFormat: AVAudioFormat?
    private var isStarted = false
    private var muted = true

    init() {
        engine.attach(player)
    }

    func setMuted(_ m: Bool) {
        lock.lock()
        let wasMuted = muted
        muted = m
        let started = isStarted
        lock.unlock()
        guard wasMuted != m else { return }
        if m {
            player.pause()
            DebugLog.write("audio player muted")
        } else if started {
            player.play()
            DebugLog.write("audio player unmuted (engine running)")
        }
    }

    func schedule(samples: UnsafePointer<Float>,
                  sampleRate: Int32,
                  channels: Int32,
                  samplesPerChannel: Int32,
                  channelStrideBytes: Int32) {
        guard channels > 0, samplesPerChannel > 0, sampleRate > 0 else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(sampleRate),
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false) else { return }

        lock.lock()
        let formatChanged = currentFormat == nil
            || currentFormat?.sampleRate != format.sampleRate
            || currentFormat?.channelCount != format.channelCount
        let m = muted
        lock.unlock()

        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samplesPerChannel)) else { return }
        buf.frameLength = AVAudioFrameCount(samplesPerChannel)

        guard let chData = buf.floatChannelData else { return }
        let strideFloats = Int(channelStrideBytes) / MemoryLayout<Float>.stride
        let bytesPerChannel = Int(samplesPerChannel) * MemoryLayout<Float>.stride
        for ch in 0..<Int(channels) {
            let src = samples.advanced(by: ch * strideFloats)
            memcpy(chData[ch], src, bytesPerChannel)
        }

        schedule(buffer: buf, formatChanged: formatChanged, muted: m)
    }

    /// Link delivers timestamped PCM sample buffers so the same packet can feed
    /// both monitoring and `Recorder`. The LiveKit adapter normalizes these to
    /// interleaved Float32; reject other layouts truthfully instead of playing
    /// corrupt audio.
    func schedule(sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbdPointer.pointee.mFormatID == kAudioFormatLinearPCM,
              asbdPointer.pointee.mBitsPerChannel == 32,
              asbdPointer.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let asbd = asbdPointer.pointee
        let channels = Int(asbd.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channels > 0, frames > 0 else { return }

        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer,
              length >= frames * channels * MemoryLayout<Float>.stride,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: asbd.mSampleRate,
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channelData = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pointer.withMemoryRebound(to: Float.self, capacity: frames * channels) { samples in
            for frame in 0..<frames {
                for channel in 0..<channels {
                    channelData[channel][frame] = samples[frame * channels + channel]
                }
            }
        }

        lock.lock()
        let formatChanged = currentFormat == nil
            || currentFormat?.sampleRate != format.sampleRate
            || currentFormat?.channelCount != format.channelCount
        let m = muted
        lock.unlock()
        schedule(buffer: buffer, formatChanged: formatChanged, muted: m)
    }

    private func schedule(buffer: AVAudioPCMBuffer, formatChanged: Bool, muted: Bool) {
        if formatChanged { setupEngine(format: buffer.format) }
        if !muted {
            player.scheduleBuffer(buffer, completionHandler: nil)
            lock.lock()
            let started = isStarted
            lock.unlock()
            if started, !player.isPlaying { player.play() }
        }
    }

    func stop() {
        lock.lock()
        let started = isStarted
        isStarted = false
        currentFormat = nil
        lock.unlock()
        if started {
            player.stop()
            engine.stop()
            DebugLog.write("audio player stopped")
        }
    }

    private func setupEngine(format: AVAudioFormat) {
        lock.lock()
        let started = isStarted
        lock.unlock()
        if started {
            player.stop()
            engine.stop()
        }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            lock.lock()
            isStarted = true
            currentFormat = format
            let m = muted
            lock.unlock()
            if !m { player.play() }
            DebugLog.write("audio engine started sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
        } catch {
            DebugLog.write("ERROR audio engine start failed: \(error.localizedDescription)")
            lock.lock()
            isStarted = false
            currentFormat = nil
            lock.unlock()
        }
    }
}
