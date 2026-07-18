import Foundation
import Testing
@testable import Clip

@Suite("Application update configuration")
struct ApplicationUpdateConfigurationTests {
    @MainActor
    @Test("A deliberately dormant updater cannot begin an update check")
    func dormantUpdaterIsInert() {
        let updater = SparkleApplicationUpdater(startingUpdater: false)

        #expect(updater.canCheckForUpdates == false)
        updater.checkForUpdates()
        #expect(updater.canCheckForUpdates == false)
    }

    @MainActor
    @Test("The menu action forwards one explicit update request")
    func menuActionForwardsUpdateRequest() {
        var requestCount = 0
        let actions = MenuBarActions(
            captureArea: {},
            lastArea: {},
            fullscreen: {},
            openHistory: {},
            openSettings: {},
            checkForUpdates: { requestCount += 1 },
            quit: {}
        )

        actions.checkForUpdates()

        #expect(requestCount == 1)
    }

    @Test("The hosted app has one secure public GitHub update feed")
    func secureFeedConfiguration() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let feed = try #require(info["SUFeedURL"] as? String)
        let feedURL = try #require(URL(string: feed))

        #expect(feedURL.scheme == "https")
        #expect(feedURL.host == "tomas-lejdung.github.io")
        #expect(feedURL.path == "/Clip/appcast.xml")
        #expect(feedURL.query == nil)
        #expect(feedURL.fragment == nil)
    }

    @Test("Sparkle archive signing and sandbox installation are enabled")
    func signingAndSandboxConfiguration() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let encodedPublicKey = try #require(info["SUPublicEDKey"] as? String)
        let publicKey = try #require(Data(base64Encoded: encodedPublicKey))

        #expect(publicKey.count == 32)
        #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
    }

    @Test("Release versions are suitable for Sparkle comparison")
    func validReleaseVersions() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let marketingVersion = try #require(
            info["CFBundleShortVersionString"] as? String
        )
        let buildVersion = try #require(info["CFBundleVersion"] as? String)

        #expect(matches(marketingVersion, #"^[0-9]+\.[0-9]+\.[0-9]+$"#))
        #expect(matches(buildVersion, #"^[1-9][0-9]*$"#))
    }

    private func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
