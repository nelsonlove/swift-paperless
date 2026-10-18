//
//  FileProviderSmokeTests.swift
//  swift-paperlessUITests
//
//  Simulator smoke test of the File Provider extension through the Files app:
//  seed the mock library, switch its location on in Files, open it, and check
//  that the folders and a document are listed. Every step attaches a
//  screenshot (kept, also on success); a failure also attaches the Files
//  app's element tree. Labels in Files differ between iOS versions, so each
//  lookup tries several.
//
//  Needs a Debug build of the app with the `--seed-mock-library` launch
//  argument, the domain sync and the extension. Run it with
//  `scripts/first_build.sh`.
//

import XCTest

@MainActor
final class FileProviderSmokeTests: XCTestCase {
  private let paperless = XCUIApplication()
  private let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")

  /// The made-up library of `MockLibrary`: the location's names (the
  /// domain's display name, or the app's name, which is what iOS 26.5 shows
  /// for an app with one domain), a correspondent folder of the default
  /// layout, and one of its documents.
  private let locationNames = ["Mock Paperless", "Paperless"]
  private var locationName: String { locationNames[0] }
  private let correspondentFolder = "Acme Utilities"
  private let browseFolders = ["By tag", "By correspondent", "By type"]
  private let documentTitle = "Electricity bill March 2026"

  private var step = 0

  override func setUp() async throws {
    continueAfterFailure = false
  }

  /// Fails the test unless `condition` holds, first attaching the Files app's
  /// element tree and the screen, so a label that changed in a new iOS
  /// version can be read from the result bundle.
  private func require(
    _ condition: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard !condition else { return }
    let tree = XCTAttachment(string: files.debugDescription)
    tree.name = "Files element tree at failure"
    tree.lifetime = .keepAlways
    add(tree)
    let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screen.name = "Screen at failure"
    screen.lifetime = .keepAlways
    add(screen)
    XCTFail(message, file: file, line: line)
  }

  func testMockLibraryIsListedInFiles() throws {
    // 1. Seed the library; the app's list shows the seeded documents.
    paperless.launchArguments = ["--seed-mock-library"]
    paperless.launch()
    let seeded = element(in: paperless, labelsStartingWith: [documentTitle])
    require(
      seeded.waitForExistence(timeout: 60), "The seeded library did not appear in the app")
    // The domain is added by the app's launch task; give it a moment.
    sleep(3)
    snapshot(paperless, "app seeded")

    // 2. Files, Browse tab, at the top level.
    files.launch()
    require(files.wait(for: .runningForeground, timeout: 30), "Files did not start")
    snapshot(files, "files opened")
    let browse = element(in: files, labels: ["Browse"], types: [.button])
    require(browse.waitForExistence(timeout: 15), "No Browse tab")
    browse.tap()
    // A second tap returns to the top of Browse when Files remembered a folder.
    if !isVisible(element(in: files, labels: ["Locations"]), timeout: 2) {
      browse.tap()
    }
    snapshot(files, "browse")

    // 3. Switch the location on if Files lists it as off.
    let location = locationCell()
    if !isVisible(location, timeout: 3) {
      enableLocation()
    }
    require(location.waitForExistence(timeout: 15), "No \(locationName) location in Browse")
    snapshot(files, "location listed")

    // 4. Open the location: the canonical folders and the browse folders.
    location.tap()
    let acme = element(in: files, labelsStartingWith: [correspondentFolder])
    require(
      acme.waitForExistence(timeout: 60), "No \(correspondentFolder) folder in \(locationName)")
    for name in browseFolders {
      require(
        element(in: files, labelsStartingWith: [name]).waitForExistence(timeout: 10),
        "No \(name) folder in \(locationName)")
    }
    snapshot(files, "location opened")

    // 5. Open a folder: one of its documents.
    acme.tap()
    let document = element(in: files, labelsStartingWith: [documentTitle])
    require(
      document.waitForExistence(timeout: 60), "No \(documentTitle) in \(correspondentFolder)")
    snapshot(files, "folder opened")
  }

  /// Browse → "…" → Edit → the location's switch on → Done.
  private func enableLocation() {
    let more = element(
      in: files, labels: ["More", "More options", "Show more", "ellipsis", "ellipsis.circle", "…"],
      types: [.button])
    require(more.waitForExistence(timeout: 10), "No \"…\" button in Browse")
    more.tap()
    snapshot(files, "more menu")

    let edit = element(in: files, labels: ["Edit", "Edit Sidebar"], types: [.button, .menuItem])
    require(edit.waitForExistence(timeout: 10), "No Edit item in the menu")
    edit.tap()
    snapshot(files, "editing locations")

    // The switch is a sibling of the location's cell, not inside it (iOS
    // 26.5): take the switch on the cell's row.
    let row = locationCell()
    require(row.waitForExistence(timeout: 10), "No \(locationName) row while editing")
    let rowFrame = row.frame
    let rowSwitch = files.switches.allElementsBoundByIndex.first {
      $0.frame.midY >= rowFrame.minY && $0.frame.midY <= rowFrame.maxY
    }
    require(rowSwitch != nil, "No switch on the \(locationName) row")
    if let rowSwitch, (rowSwitch.value as? String) != "1" { rowSwitch.tap() }
    snapshot(files, "location switched on")

    let done = element(in: files, labels: ["Done"], types: [.button])
    require(done.waitForExistence(timeout: 10), "No Done button")
    done.tap()
  }

  // MARK: Helpers

  /// The location's row in Browse, by any of its names. A cell, so the "◀
  /// Paperless" button back to the app is never taken for it.
  private func locationCell() -> XCUIElement {
    files.cells.matching(NSPredicate(format: "label IN %@", locationNames)).firstMatch
  }

  private func element(
    in app: XCUIApplication, labels: [String], types: [XCUIElement.ElementType] = []
  ) -> XCUIElement {
    let predicate = NSPredicate(format: "label IN %@ OR identifier IN %@", labels, labels)
    if types.isEmpty {
      return app.descendants(matching: .any).matching(predicate).firstMatch
    }
    let typed = NSPredicate(
      format: "elementType IN %@", types.map { NSNumber(value: $0.rawValue) })
    return app.descendants(matching: .any)
      .matching(NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, typed]))
      .firstMatch
  }

  /// Matches labels that start with a name, so "Electricity bill March 2026"
  /// finds the file whether or not Files shows its ".pdf".
  private func element(in app: XCUIApplication, labelsStartingWith names: [String]) -> XCUIElement {
    let predicates = names.map { NSPredicate(format: "label BEGINSWITH %@", $0) }
    return app.descendants(matching: .any)
      .matching(NSCompoundPredicate(orPredicateWithSubpredicates: predicates))
      .firstMatch
  }

  private func isVisible(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    element.waitForExistence(timeout: timeout)
  }

  private func snapshot(_ app: XCUIApplication, _ name: String) {
    step += 1
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = String(format: "%02d %@", step, name)
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
