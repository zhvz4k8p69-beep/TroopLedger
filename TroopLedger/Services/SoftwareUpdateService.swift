#if os(macOS)
import Combine
import Foundation
import Sparkle

/// One updater shared by all windows. Sparkle owns its preferences and update scheduling.
@MainActor
final class SoftwareUpdateService: ObservableObject {
    static let shared = SoftwareUpdateService()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var configurationError: String?
    private let controller: SPUStandardUpdaterController

    init(bundle: Bundle = .main, startsUpdater: Bool = true) {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        configurationError = Self.configurationIssue(info: bundle.infoDictionary ?? [:])
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: DispatchQueue.main).assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.lastUpdateCheckDate).receive(on: DispatchQueue.main).assign(to: &$lastUpdateCheckDate)
        let runningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
        if startsUpdater, !runningTests, configurationError == nil {
            do { try controller.updater.start() }
            catch { configurationError = error.localizedDescription }
        }
    }

    func checkForUpdates() {
        guard configurationError == nil, canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard configurationError == nil else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    static func configurationIssue(info: [String: Any]) -> String? {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, !feed.contains("$(") else {
            return "Software updates are not configured in this build: a secure update feed is required."
        }
        guard let publicKey = info["SUPublicEDKey"] as? String,
              let data = Data(base64Encoded: publicKey), data.count == 32 else {
            return "Software updates are not configured in this build: the update verification key is missing."
        }
        return nil
    }
}
#endif
