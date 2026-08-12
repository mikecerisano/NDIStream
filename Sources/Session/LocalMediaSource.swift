import CoreMedia
import CoreVideo
import Foundation

/// Application-owned captured media that can feed preview, recorder, and transport
/// without any consumer opening a second capture session.
public final class LocalMediaSource {
    struct VideoFrame {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
        let frameRateN: Int32
        let frameRateD: Int32
    }

    public final class Subscription {
        public struct Statistics: Equatable {
            public let droppedVideoFrames: UInt64
        }

        fileprivate let id = UUID()
        fileprivate weak var owner: LocalMediaSource?
        fileprivate let queue: DispatchQueue
        fileprivate let onVideoFrame: (CVPixelBuffer, CMTime) -> Void
        fileprivate let onAudioSampleBuffer: (CMSampleBuffer) -> Void
        fileprivate let lock = NSLock()
        fileprivate var deliveringVideo = false
        fileprivate var pendingVideo: VideoFrame?
        fileprivate var droppedVideoFrames: UInt64 = 0

        fileprivate init(
            owner: LocalMediaSource,
            queue: DispatchQueue,
            onVideoFrame: @escaping (CVPixelBuffer, CMTime) -> Void,
            onAudioSampleBuffer: @escaping (CMSampleBuffer) -> Void
        ) {
            self.owner = owner
            self.queue = queue
            self.onVideoFrame = onVideoFrame
            self.onAudioSampleBuffer = onAudioSampleBuffer
        }

        public var statistics: Statistics {
            lock.lock()
            defer { lock.unlock() }
            return Statistics(droppedVideoFrames: droppedVideoFrames)
        }

        public func cancel() {
            owner?.remove(id: id)
            owner = nil
        }

        deinit { cancel() }

        fileprivate func offer(video frame: VideoFrame) {
            lock.lock()
            if deliveringVideo {
                if pendingVideo != nil { droppedVideoFrames += 1 }
                pendingVideo = frame
                lock.unlock()
                return
            }
            deliveringVideo = true
            lock.unlock()
            deliver(frame)
        }

        private func deliver(_ frame: VideoFrame) {
            queue.async { [weak self] in
                guard let self else { return }
                self.onVideoFrame(frame.pixelBuffer, frame.presentationTime)
                self.lock.lock()
                if let pending = self.pendingVideo {
                    self.pendingVideo = nil
                    self.lock.unlock()
                    self.deliver(pending)
                } else {
                    self.deliveringVideo = false
                    self.lock.unlock()
                }
            }
        }

        fileprivate func offer(audio sampleBuffer: CMSampleBuffer) {
            queue.async { [weak self] in self?.onAudioSampleBuffer(sampleBuffer) }
        }
    }

    private let lock = NSLock()
    private var subscriptions: [UUID: Subscription] = [:]

    public init() {}

    @discardableResult
    public func subscribe(
        queue: DispatchQueue,
        onVideoFrame: @escaping (CVPixelBuffer, CMTime) -> Void,
        onAudioSampleBuffer: @escaping (CMSampleBuffer) -> Void
    ) -> Subscription {
        let subscription = Subscription(
            owner: self,
            queue: queue,
            onVideoFrame: onVideoFrame,
            onAudioSampleBuffer: onAudioSampleBuffer
        )
        lock.lock()
        subscriptions[subscription.id] = subscription
        lock.unlock()
        return subscription
    }

    public func emitVideo(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        frameRateN: Int32 = 30,
        frameRateD: Int32 = 1
    ) {
        let frame = VideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            frameRateN: frameRateN,
            frameRateD: frameRateD
        )
        snapshot().forEach { $0.offer(video: frame) }
    }

    public func emitAudio(_ sampleBuffer: CMSampleBuffer) {
        snapshot().forEach { $0.offer(audio: sampleBuffer) }
    }

    private func snapshot() -> [Subscription] {
        lock.lock()
        defer { lock.unlock() }
        return Array(subscriptions.values)
    }

    private func remove(id: UUID) {
        lock.lock()
        subscriptions.removeValue(forKey: id)
        lock.unlock()
    }
}
