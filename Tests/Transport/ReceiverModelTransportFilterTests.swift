import XCTest
@testable import NDIStream

@MainActor
final class ReceiverModelTransportFilterTests: XCTestCase {

    func testSelectedTransportPersistsToUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "receiverLinkMode")
        UserDefaults.standard.removeObject(forKey: "receiverTransport")
        let model = ReceiverModel()
        XCTAssertEqual(model.selectedTransport, .link, "Link is the new default")
        model.selectedTransport = .ndi
        let stored = UserDefaults.standard.string(forKey: "receiverLinkMode")
        XCTAssertEqual(stored, "ndi")
    }

    func testLegacyWarpStreamMigratesToLink() {
        UserDefaults.standard.removeObject(forKey: "receiverLinkMode")
        UserDefaults.standard.set("warpStream", forKey: "receiverTransport")
        let model = ReceiverModel()
        XCTAssertEqual(model.selectedTransport, .link)
        UserDefaults.standard.removeObject(forKey: "receiverLinkMode")
        UserDefaults.standard.removeObject(forKey: "receiverTransport")
    }

    func testLegacyNDIRestoresAsNDI() {
        UserDefaults.standard.removeObject(forKey: "receiverLinkMode")
        UserDefaults.standard.set("ndi", forKey: "receiverTransport")
        let model = ReceiverModel()
        XCTAssertEqual(model.selectedTransport, .ndi)
        UserDefaults.standard.removeObject(forKey: "receiverLinkMode")
        UserDefaults.standard.removeObject(forKey: "receiverTransport")
    }

    func testNewModePreferenceWinsOverLegacyPreference() {
        UserDefaults.standard.set("ndi", forKey: "receiverLinkMode")
        UserDefaults.standard.set("warpStream", forKey: "receiverTransport")
        let model = ReceiverModel()
        XCTAssertEqual(model.selectedTransport, .ndi)
        UserDefaults.standard.removeObject(forKey: "receiverLinkMode")
        UserDefaults.standard.removeObject(forKey: "receiverTransport")
    }
}
