import CoreMedia
import XCTest
@testable import NDIStream

final class LiveKitSDKClientTests: XCTestCase {
    func testClientCanBeCreatedWithoutStartingCaptureOrConnecting() {
        _ = LiveKitSDKClient()
    }

    func testErrorDescriptionRedactsExactAccessToken() {
        let token = "secret-token-123"
        let error = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "join failed token=\(token)"]
        )

        let message = LiveKitSDKClient.redactedDescription(of: error, token: token)

        XCTAssertFalse(message.contains(token))
        XCTAssertTrue(message.contains("<redacted>"))
    }

    func testApplicationOwnedCaptureRejectsSecondLiveKitMicrophoneGraph() async {
        let client = LiveKitSDKClient(microphoneCaptureOwnership: .application)

        do {
            try await client.setMicrophoneEnabled(true)
            XCTFail("Expected single-owner capture policy to reject LiveKit microphone capture")
        } catch let error as LiveKitSDKClient.ConnectionError {
            XCTAssertEqual(error.message, LiveKitSDKClient.externalMicrophoneCaptureMessage)
            XCTAssertTrue(error.message.contains("second capture graph"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
