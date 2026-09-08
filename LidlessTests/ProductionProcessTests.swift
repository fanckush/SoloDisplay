import Foundation
import Testing

@testable import Lidless

struct ProductionProcessTests {
  @Test func aNormalLaunchBecomesTheSupervisingHelper() throws {
    #expect(try ProductionLaunch.role(arguments: [], pipedStandardStreams: false) == .helper)
    #expect(
      try ProductionLaunch.role(arguments: ["--diagnostics"], pipedStandardStreams: false)
        == .helper)
    // Inherited pipes without the argument are not a claim to the controller role.
    #expect(try ProductionLaunch.role(arguments: [], pipedStandardStreams: true) == .helper)
  }

  @Test func theControllerRoleRequiresActualInheritedPipes() throws {
    #expect(
      try ProductionLaunch.role(
        arguments: [ProductionLaunch.controllerArgument], pipedStandardStreams: true)
        == .controller)
    // A command-line assertion alone can never establish the pairing.
    #expect(throws: ProductionLaunchError.self) {
      try ProductionLaunch.role(
        arguments: [ProductionLaunch.controllerArgument], pipedStandardStreams: false)
    }
  }

  @Test func runningWithoutAHelperMustBeAskedForExplicitly() throws {
    #expect(
      try ProductionLaunch.role(
        arguments: [ProductionLaunch.unprotectedArgument], pipedStandardStreams: false)
        == .unprotected)
  }

  @Test func productionParsingNeverAcceptsALabCommandOrAnyOtherArgument() {
    for argument in ["--lab-check", "--lab-exit-supervised", "--external", "--anything"] {
      #expect(throws: ProductionLaunchError.self) {
        try ProductionLaunch.role(arguments: [argument], pipedStandardStreams: true)
      }
    }
  }

  @Test func unavailabilityAlwaysCarriesAnExplanation() {
    #expect(ProductionAvailability.protectedIdle.explanation == nil)
    let reason = ProductionAvailability.unavailable("No recovery helper.")
    #expect(reason.explanation == "No recovery helper.")
  }
}
