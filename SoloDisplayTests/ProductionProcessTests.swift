import Foundation
import Testing
@testable import SoloDisplay

struct ProductionProcessTests {
  @Test func aNormalLaunchBecomesTheApp() throws {
    #expect(try ProductionLaunch.role(arguments: [], pipedStandardStreams: false) == .app)
    #expect(
      try ProductionLaunch.role(arguments: ["--diagnostics"], pipedStandardStreams: false) == .app
    )
    // Inherited pipes without an argument are not a claim to a child role.
    #expect(try ProductionLaunch.role(arguments: [], pipedStandardStreams: true) == .app)
  }

  @Test func childRolesRequireActualInheritedPipes() throws {
    for (argument, role) in [
      (ProductionLaunch.guardianArgument, ProductionRole.guardian),
      (ProductionLaunch.workerArgument, .worker)
    ] {
      #expect(try ProductionLaunch.role(arguments: [argument], pipedStandardStreams: true) == role)
      // A command-line assertion alone can never establish the pairing.
      #expect(throws: ProductionLaunchError.self) {
        try ProductionLaunch.role(arguments: [argument], pipedStandardStreams: false)
      }
    }
  }

  @Test func onlyOneRoleCanBeSelected() {
    #expect(throws: ProductionLaunchError.self) {
      try ProductionLaunch.role(
        arguments: [ProductionLaunch.guardianArgument, ProductionLaunch.workerArgument],
        pipedStandardStreams: true
      )
    }
  }

  @Test func runningReadOnlyMustBeAskedForExplicitly() throws {
    #expect(
      try ProductionLaunch.role(
        arguments: [ProductionLaunch.unprotectedArgument], pipedStandardStreams: false
      )
        == .unprotected
    )
  }

  @Test func productionParsingNeverAcceptsALabCommandOrAnyOtherArgument() {
    for argument in ["--lab-check", "--solodisplay-controller", "--external", "--anything"] {
      #expect(throws: ProductionLaunchError.self) {
        try ProductionLaunch.role(arguments: [argument], pipedStandardStreams: true)
      }
    }
  }
}
