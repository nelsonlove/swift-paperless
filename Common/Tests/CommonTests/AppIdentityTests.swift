import Foundation
import Testing

@testable import Common

@Suite
struct AppIdentityTests {
  /// Makes a bundle in a temporary folder whose Info.plist holds `info`, runs
  /// `body` with it, and removes the folder.
  private func withBundle(_ info: [String: Any], _ body: (Bundle) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppIdentityTests-\(UUID().uuidString).bundle")
    defer { try? FileManager.default.removeItem(at: url) }
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    try body(try #require(Bundle(url: url)))
  }

  @Test("the host test runner has no bundle id and gets the upstream identity")
  func hostFallsBack() {
    #expect(AppIdentity.bundleIDPrefix == AppIdentity.defaultBundleIDPrefix)
    #expect(AppIdentity.appGroup == AppIdentity.defaultAppGroup)
    #expect(AppGroup.identifier == AppIdentity.defaultAppGroup)
  }

  @Test("an expanded Info.plist value is used")
  func readsKey() throws {
    try withBundle(["CFBundleIdentifier": "com.example.app", "Group": "group.com.example.app"]) {
      var missing: [String] = []
      let value = AppIdentity.resolve("Group", default: "x", bundle: $0) { missing.append($0) }
      #expect(value == "group.com.example.app")
      #expect(missing.isEmpty)
    }
  }

  @Test("a missing, empty or unexpanded value is ignored")
  func ignoresBadValues() throws {
    try withBundle(["Empty": "", "Unexpanded": "$(SWP_APP_GROUP)"]) {
      #expect(AppIdentity.infoValue("Missing", bundle: $0) == nil)
      #expect(AppIdentity.infoValue("Empty", bundle: $0) == nil)
      #expect(AppIdentity.infoValue("Unexpanded", bundle: $0) == nil)
    }
  }

  @Test("a bundle without an id falls back silently")
  func noBundleIDIsSilent() throws {
    try withBundle(["Unexpanded": "$(SWP_APP_GROUP)"]) {
      var missing: [String] = []
      let value = AppIdentity.resolve("Unexpanded", default: "fb", bundle: $0) {
        missing.append($0)
      }
      #expect(value == "fb")
      #expect(missing.isEmpty)
    }
  }

  @Test("a real bundle without the key reports it, then falls back")
  func realBundleReports() throws {
    try withBundle(["CFBundleIdentifier": "com.example.app", "Unexpanded": "$(SWP_APP_GROUP)"]) {
      var missing: [String] = []
      #expect(
        AppIdentity.resolve("Unexpanded", default: "fb", bundle: $0) { missing.append($0) } == "fb")
      #expect(
        AppIdentity.resolve("Missing", default: "fb", bundle: $0) { missing.append($0) } == "fb")
      #expect(missing == ["Unexpanded", "Missing"])
    }
  }

  @Test("the Swift defaults equal Config/Shared/Identity.xcconfig")
  func defaultsMatchXcconfig() throws {
    let xcconfig = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // CommonTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // Common
      .deletingLastPathComponent()  // repository root
      .appendingPathComponent("Config/Shared/Identity.xcconfig")
    var settings: [String: String] = [:]
    for line in try String(contentsOf: xcconfig, encoding: .utf8).split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.hasPrefix("//"), let eq = trimmed.firstIndex(of: "=") else { continue }
      settings[trimmed[..<eq].trimmingCharacters(in: .whitespaces)] =
        trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    }
    #expect(settings["SWP_BUNDLE_ID_PREFIX"] == AppIdentity.defaultBundleIDPrefix)
    #expect(settings["SWP_APP_GROUP"] == AppIdentity.defaultAppGroup)
  }
}
