import XCTest

final class LidlessUITests: XCTestCase {
  @MainActor
  func testDiagnosticsAreExplicitlyReadOnly() {
    let app = XCUIApplication()
    app.launchArguments = ["--diagnostics"]
    app.launch()
    XCTAssertTrue(app.staticTexts["diagnosticsTitle"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["readOnlyNotice"].exists)
    let refresh = app.buttons["refreshDiagnostics"]
    XCTAssertTrue(refresh.isEnabled)
    refresh.click()
    let refreshEvent = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Manual refresh")
    ).firstMatch
    XCTAssertTrue(refreshEvent.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["readOnlyNotice"].exists)
  }
}
