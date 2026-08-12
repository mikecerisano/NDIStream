import CoreMedia
import CoreVideo
import XCTest
@testable import NDIStream

final class MediaSessionContractTests: XCTestCase {
    func testSessionConfigurationDoesNotEncodeOrPersistToken() throws {
        let configuration = SessionConfiguration(
            serverURL: URL(string: "wss://example.invalid"),
            roomName: "room",
            displayName: "Camera A",
            accessToken: "top-secret"
        )

        let data = try JSONEncoder().encode(configuration)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("top-secret"))
        XCTAssertFalse(json.contains("accessToken"))
        XCTAssertEqual(try JSONDecoder().decode(SessionConfiguration.self, from: data).accessToken, nil)
    }

    func testRemoteTrackIdentityUsesParticipantAndTrackIDs() {
        let first = RemoteMediaTrack(
            id: MediaTrackID(rawValue: "camera"),
            participantID: ParticipantID(rawValue: "participant-a"),
            participantName: "Camera",
            kind: .camera,
            isMuted: false
        )
        let second = RemoteMediaTrack(
            id: MediaTrackID(rawValue: "camera"),
            participantID: ParticipantID(rawValue: "participant-b"),
            participantName: "Camera",
            kind: .camera,
            isMuted: false
        )

        XCTAssertNotEqual(first.selectionID, second.selectionID)
    }

    func testLocalMediaSourceDeliversVideoAndAudioToMultipleSubscribers() throws {
        let source = LocalMediaSource()
        let firstVideo = expectation(description: "first video")
        let secondVideo = expectation(description: "second video")
        let firstAudio = expectation(description: "first audio")
        let secondAudio = expectation(description: "second audio")

        let tokenA = source.subscribe(
            queue: DispatchQueue(label: "test.source.a"),
            onVideoFrame: { _, pts in
                XCTAssertEqual(pts, CMTime(value: 12, timescale: 30))
                firstVideo.fulfill()
            },
            onAudioSampleBuffer: { _ in firstAudio.fulfill() }
        )
        let tokenB = source.subscribe(
            queue: DispatchQueue(label: "test.source.b"),
            onVideoFrame: { _, _ in secondVideo.fulfill() },
            onAudioSampleBuffer: { _ in secondAudio.fulfill() }
        )

        source.emitVideo(try makePixelBuffer(), presentationTime: CMTime(value: 12, timescale: 30))
        source.emitAudio(try makeAudioSampleBuffer())

        wait(for: [firstVideo, secondVideo, firstAudio, secondAudio], timeout: 2)
        withExtendedLifetime([tokenA, tokenB]) {}
    }

    func testLocalMediaSourceDropsSupersededVideoUnderBackpressure() throws {
        let source = LocalMediaSource()
        let firstEntered = expectation(description: "first entered")
        let finalDelivered = expectation(description: "final delivered")
        let releaseFirst = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var delivered: [Int64] = []

        let token = source.subscribe(
            queue: DispatchQueue(label: "test.source.backpressure"),
            onVideoFrame: { _, pts in
                lock.lock()
                delivered.append(pts.value)
                let isFirst = delivered.count == 1
                lock.unlock()
                if isFirst {
                    firstEntered.fulfill()
                    _ = releaseFirst.wait(timeout: .now() + 2)
                } else if pts.value == 20 {
                    finalDelivered.fulfill()
                }
            },
            onAudioSampleBuffer: { _ in }
        )

        let pixelBuffer = try makePixelBuffer()
        source.emitVideo(pixelBuffer, presentationTime: CMTime(value: 1, timescale: 30))
        wait(for: [firstEntered], timeout: 2)
        for value in 2...20 {
            source.emitVideo(pixelBuffer, presentationTime: CMTime(value: Int64(value), timescale: 30))
        }
        releaseFirst.signal()
        wait(for: [finalDelivered], timeout: 2)

        lock.lock()
        let result = delivered
        lock.unlock()
        XCTAssertEqual(result, [1, 20])
        XCTAssertEqual(token.statistics.droppedVideoFrames, 18)
    }

    func testCameraManagerAttachmentUsesExistingCaptureCallbacks() throws {
        let manager = CameraManager()
        let source = LocalMediaSource()
        source.attach(to: manager)

        XCTAssertNotNil(manager.onFrame)
        XCTAssertNotNil(manager.onAudioSampleBuffer)

        source.detach(from: manager)
        XCTAssertNil(manager.onFrame)
        XCTAssertNil(manager.onAudioSampleBuffer)
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        ), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func makeAudioSampleBuffer() throws -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        ), noErr)
        let block = try XCTUnwrap(CMBlockBuffer.createWithMemoryBlock(length: 4))
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var size = 4
        XCTAssertEqual(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: try XCTUnwrap(description),
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer
        ), noErr)
        return try XCTUnwrap(sampleBuffer)
    }
}

private extension CMBlockBuffer {
    static func createWithMemoryBlock(length: Int) throws -> CMBlockBuffer {
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else {
            throw NSError(domain: "MediaSessionContractTests", code: Int(status))
        }
        return block
    }
}
