import CoreMedia
import XCTest
@testable import NDIStream

final class LiveKitSDKClientTests: XCTestCase {
    func testClientCanBeCreatedWithoutStartingCaptureOrConnecting() {
        _ = LiveKitSDKClient()
    }

    func testCallConnectOptionsDisableAutomaticSubscription() {
        XCTAssertFalse(LiveKitSDKClient.callConnectOptions().autoSubscribe)
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

    func testApplicationOwnedCaptureEnablesManualAudioWithoutSecondMicrophoneGraph() async throws {
        let client = LiveKitSDKClient(microphoneCaptureOwnership: .application)
        XCTAssertEqual(client.microphoneCaptureOwnership, .application)
        XCTAssertFalse(client.usesSDKMicrophoneCapture)
    }
}
