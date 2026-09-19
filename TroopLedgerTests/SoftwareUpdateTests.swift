import XCTest
@testable import TroopLedger

@MainActor
final class SoftwareUpdateTests: XCTestCase {
    private var info: [String: Any] {
        ["SUFeedURL": "https://example.org/updates/appcast.xml",
         "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]
    }
    func testBuiltApplicationHasPermanentFeedAndVerificationKey() {
        let builtInfo = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(builtInfo["SUFeedURL"] as? String,
            "https://github.com/zhvz4k8p69-beep/mac-updates/releases/download/updates/TroopLedger-appcast.xml")
        XCTAssertNil(SoftwareUpdateService.configurationIssue(info: builtInfo))
        XCTAssertEqual(builtInfo["SUEnableInstallerLauncherService"] as? Bool, true)
    }
    func testValidSecureFeedAndKey() {
        XCTAssertNil(SoftwareUpdateService.configurationIssue(info: info))
    }
    func testRejectsInsecureMissingAndUnexpandedFeeds() {
        for feed in ["", "http://example.org/appcast.xml", "$(SPARKLE_FEED_URL)", "https://user:secret@example.org/feed"] {
            var value = info
            value["SUFeedURL"] = feed
            XCTAssertNotNil(SoftwareUpdateService.configurationIssue(info: value), feed)
        }
    }
    func testRejectsMissingOrMalformedSigningKey() {
        for key in ["", "not-a-key", Data(repeating: 1, count: 31).base64EncodedString()] {
            var value = info
            value["SUPublicEDKey"] = key
            XCTAssertNotNil(SoftwareUpdateService.configurationIssue(info: value))
        }
    }
}
