import Foundation
import Testing

@testable import Common

@Suite
struct AppIdentityTests {
  /// A bundle in a temporary folder whose Info.plist holds `info`.
  private func bundle(_ info: [String: Any]) throws -> Bundle {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppIdentityTests-\(UUID().uuidString).bundle")
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return try #require(Bundle(url: url))
  }

  @Test("the host test runner has no keys and gets the upstream identity")
  func hostFallsBack() {
    #expect(AppIdentity.bundleIDPrefix == AppIdentity.defaultBundleIDPrefix)
    #expect(AppIdentity.appGroup == AppIdentity.defaultAppGroup)
    #expect(AppGroup.identifier == AppIdentity.defaultAppGroup)
  }

  @Test("an expanded Info.plist value is used")
  func readsKey() throws {
    let b = try bundle(["SWPAppGroupIdentifier": "group.com.example.app"])
    #expect(AppIdentity.infoValue("SWPAppGroupIdentifier", bundle: b) == "group.com.example.app")
  }

  @Test("a missing, empty or unexpanded value is ignored")
  func ignoresBadValues() throws {
    let b = try bundle(["Empty": "", "Unexpanded": "$(SWP_APP_GROUP)"])
    #expect(AppIdentity.infoValue("Missing", bundle: b) == nil)
    #expect(AppIdentity.infoValue("Empty", bundle: b) == nil)
    #expect(AppIdentity.infoValue("Unexpanded", bundle: b) == nil)
  }
}
