import Foundation
import Testing

struct PrivacyManifestTests {
    @Test func appAndNotificationExtensionBundleRequiredReasonDeclarations() throws {
        let appURL = Bundle.main.bundleURL
        let extensionURL = try #require(Bundle.main.builtInPlugInsURL)
            .appendingPathComponent("NotificationServiceExtension.appex")
        for bundleURL in [appURL, extensionURL] {
            let data = try Data(contentsOf: bundleURL.appendingPathComponent("PrivacyInfo.xcprivacy"))
            let manifest = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            let entries = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
            let reasons = try Dictionary(uniqueKeysWithValues: entries.map { entry in
                (try #require(entry["NSPrivacyAccessedAPIType"] as? String),
                 Set(try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])))
            })
            #expect(reasons["NSPrivacyAccessedAPICategoryUserDefaults"] == ["CA92.1", "1C8F.1"])
            #expect(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"] == ["C617.1"])
            #expect(reasons["NSPrivacyAccessedAPICategorySystemBootTime"] == ["35F9.1"])
        }
    }
}
