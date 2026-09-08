import XCTest

final class LidlessUITests: XCTestCase {
  @MainActor
  func testDiagnosticsAreExplicitlyReadOnly() {
    let app = XCUIApplication()
    // Run the interface alone. A normal launch becomes the supervising helper, which owns no
    // window, and a second pair would be refused while one already holds the login session.
    app.launchArguments = ["--lidless-unprotected", "--diagnostics"]
    app.launch()
    XCTAssertTrue(app.staticTexts["diagnosticsTitle"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["readOnlyNotice"].exists)
    let counter = app.staticTexts["manualRefreshCount"]
    XCTAssertTrue(counter.waitForExistence(timeout: 5))
    // SwiftUI puts a Text's content in `value`, not `label`.
    XCTAssertEqual(counter.value as? String, "Manual refreshes: 0")
    let refresh = app.buttons["refreshDiagnostics"]
    XCTAssertTrue(refresh.isEnabled)
    refresh.click()
    // A periodic sample can land after the manual one, so count refreshes rather than
    // reading whichever entry happens to be newest.
    let refreshed = NSPredicate(format: "value == %@", "Manual refreshes: 1")
    let done = XCTNSPredicateExpectation(predicate: refreshed, object: counter)
    XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 5), .completed)
    XCTAssertTrue(app.staticTexts["readOnlyNotice"].exists)
  }
}
