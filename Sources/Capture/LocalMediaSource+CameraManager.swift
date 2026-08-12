import Foundation

/// macOS capture composition stays outside StageGlassLinkCore. This adapter makes
/// CameraManager the sole capture owner while the shared source only fans out media.
extension LocalMediaSource {
    func attach(to cameraManager: CameraManager) {
        cameraManager.onFrame = { [weak self] pixelBuffer, pts in
            self?.emitVideo(pixelBuffer, presentationTime: pts)
        }
        cameraManager.onAudioSampleBuffer = { [weak self] sampleBuffer in
            self?.emitAudio(sampleBuffer)
        }
    }

    func detach(from cameraManager: CameraManager) {
        cameraManager.onFrame = nil
        cameraManager.onAudioSampleBuffer = nil
    }
}
