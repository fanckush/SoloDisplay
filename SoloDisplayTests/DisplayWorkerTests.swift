import Foundation
import SoloDisplayCore
import SoloDisplayPlatform
import Testing
@testable import SoloDisplay

struct DisplayWorkerTests {
  private let panel = PanelTarget(
    displayID: 1, displayUUID: "panel-uuid", bootID: "boot", loginID: 42
  )

  private func reading(
    panelPresent: Bool = true, lid: Lid = .open, panelMirrors: UInt32? = nil
  ) throws -> PlatformReading {
    var displays = [
      #"{"id":5,"uuid":"external","uuidResolvedID":5,"builtIn":false,"active":true,"online":true,"asleep":false,"mirrored":false,"width":1920,"height":1080,"originX":0,"originY":0,"modeAvailable":true,"transport":"native"}"#
    ]
    if panelPresent {
      let mirror = panelMirrors.map { #""mirrorSourceID":\#($0),"# } ?? ""
      displays.insert(
        #"{"id":1,"uuid":"panel-uuid","uuidResolvedID":1,"builtIn":true,"active":true,"online":true,"asleep":false,"mirrored":\#(panelMirrors != nil),\#(mirror)"width":1512,"height":982,"originX":0,"originY":0,"modeAvailable":true,"transport":"unclassified"}"#,
        at: 0
      )
    }
    let json = #"""
    {"schemaVersion":1,"osVersion":"synthetic","monotonicMilliseconds":100,"lid":"\#(lid.rawValue)",
     "bootID":"boot","loginID":42,"foregroundSession":"yes","backendValidated":false,
     "limitations":[],"transportEvidence":[],"controllers":[],
     "displays":[\#(displays.joined(separator: ","))]}
    """#
    return try JSONDecoder().decode(PlatformReading.self, from: Data(json.utf8))
  }

  @Test func aRequestIsBoundToItsActualParentAndACompleteTarget() throws {
    let request = DisplayWorkerRequest(parentPID: 123, enabled: true, target: panel)
    #expect(throws: Never.self) { try request.validate(actualParentPID: 123) }
    #expect(throws: DisplayWorkerError.self) { try request.validate(actualParentPID: 124) }
    var incomplete = request
    incomplete.target.displayUUID = ""
    #expect(throws: DisplayWorkerError.self) { try incomplete.validate(actualParentPID: 123) }
  }

  @Test func aDisableIsRefusedUnlessTheSamePanelIsStillThere() throws {
    let disable = DisplayWorkerRequest(parentPID: 123, enabled: false, target: panel)
    #expect(throws: Never.self) { try DisplayWorker.check(disable, against: reading()) }
    #expect(throws: DisplayWorkerError.refused) {
      try DisplayWorker.check(disable, against: reading(panelPresent: false))
    }
    #expect(throws: DisplayWorkerError.refused) {
      try DisplayWorker.check(disable, against: reading(lid: .closed))
    }
    var other = disable
    other.target.displayUUID = "another-panel"
    #expect(throws: DisplayWorkerError.refused) {
      try DisplayWorker.check(other, against: reading())
    }
  }

  /// Turning a monitor off is only ever safe while another screen is left to look at, and never
  /// when other screens are following this one.
  @Test func aMonitorIsOnlyTurnedOffWhileSomethingElseIsStillVisible() throws {
    let monitor = PanelTarget(
      displayID: 5, displayUUID: "external", bootID: "boot", loginID: 42,
      kind: .external, controller: "dispext0"
    )
    let disable = DisplayWorkerRequest(parentPID: 123, enabled: false, target: monitor)
    #expect(throws: Never.self) { try DisplayWorker.check(disable, against: reading()) }

    // The laptop panel is off, so this monitor is the only screen there is.
    #expect(throws: DisplayWorkerError.refused) {
      try DisplayWorker.check(disable, against: reading(panelPresent: false))
    }
    // A monitor that is not the one recorded at that ID is never changed in its name.
    var impostor = disable
    impostor.target.displayUUID = "someone-else"
    #expect(throws: DisplayWorkerError.refused) {
      try DisplayWorker.check(impostor, against: reading())
    }
    // The laptop panel is never turned off through the monitor path.
    var asPanel = disable
    asPanel.target.displayID = 1
    asPanel.target.displayUUID = "panel-uuid"
    #expect(throws: DisplayWorkerError.refused) {
      try DisplayWorker.check(asPanel, against: reading())
    }
  }

  /// Measured on the Dell on 2026-09-20: turning off a monitor other screens mirror collapses
  /// the mirror and the follower becomes its own display. It is not blanked, so a follower counts
  /// as a screen that will still be there afterwards.
  @Test func aMonitorOtherScreensMirrorCanStillBeTurnedOff() throws {
    let monitor = PanelTarget(
      displayID: 5, displayUUID: "external", bootID: "boot", loginID: 42,
      kind: .external, controller: "dispext0"
    )
    let disable = DisplayWorkerRequest(parentPID: 123, enabled: false, target: monitor)
    #expect(throws: Never.self) {
      try DisplayWorker.check(disable, against: reading(panelMirrors: 5))
    }
    // With no laptop panel left to inherit the picture, there would be nothing to look at.
    #expect(throws: DisplayWorkerError.refused) {
      try DisplayWorker.check(disable, against: reading(panelPresent: false))
    }
  }

  @Test func anEnableReachesAPanelThatIsOffBecauseItsParentTurnedItOff() throws {
    let enable = DisplayWorkerRequest(parentPID: 123, enabled: true, target: panel)
    #expect(throws: Never.self) {
      try DisplayWorker.check(enable, against: reading(panelPresent: false))
    }
    #expect(throws: DisplayWorkerError.refused) {
      try DisplayWorker.check(enable, against: reading(panelPresent: false, lid: .closed))
    }
  }

  @Test func aWorkerThatNeverFinishesIsKilled() {
    // `yes` ignores its request and never exits, like a private call that does not return.
    let writer = WorkerDisplayWriter(executable: URL(fileURLWithPath: "/usr/bin/yes"), timeout: 0.1)
    #expect(writer.setEnabled(true, target: panel) == .killed)
  }

  @Test func aWorkerThatCannotStartIsAFailedAttemptNotACrash() {
    let writer = WorkerDisplayWriter(executable: URL(fileURLWithPath: "/nonexistent/solodisplay"))
    #expect(writer.setEnabled(false, target: panel) == .failed)
  }

  @Test func aGuardianRequestIsBoundToItsActualParentAndACompleteTarget() {
    let request = GuardianRequest(parentPID: 321, targets: [panel])
    #expect(throws: Never.self) { try request.validate(actualParentPID: 321) }
    #expect(throws: DisplayWorkerError.self) { try request.validate(actualParentPID: 1) }
    var incomplete = request
    incomplete.targets[0].bootID = ""
    #expect(throws: DisplayWorkerError.self) { try incomplete.validate(actualParentPID: 321) }
    #expect(throws: DisplayWorkerError.self) {
      try GuardianRequest(parentPID: 321, targets: []).validate(actualParentPID: 321)
    }
  }

  /// A guardian is given everything owed at once, and told the whole set again whenever it
  /// changes. One laptop panel at most, and every target from the same login.
  @Test func aGuardianCanBeGivenMonitorsAsWellAsThePanel() {
    let monitor = PanelTarget(
      displayID: 5, displayUUID: "external", bootID: "boot", loginID: 42,
      kind: .external, controller: "dispext0"
    )
    let request = GuardianRequest(parentPID: 321, targets: [panel, monitor])
    #expect(throws: Never.self) { try request.validate(actualParentPID: 321) }
    #expect(request.panel == panel)
    #expect(request.monitors == [monitor])

    // Monitors alone are enough: the laptop screen can be on while a monitor is off.
    let monitorsOnly = GuardianRequest(parentPID: 321, targets: [monitor])
    #expect(throws: Never.self) { try monitorsOnly.validate(actualParentPID: 321) }
    #expect(monitorsOnly.panel == nil)

    var otherLogin = monitor
    otherLogin.loginID = 43
    #expect(throws: DisplayWorkerError.self) {
      try GuardianRequest(parentPID: 321, targets: [panel, otherLogin])
        .validate(actualParentPID: 321)
    }

    // An update carries everything owed, the laptop panel included: a guardian started for a
    // monitor has to learn about the panel before the screen goes off.
    #expect(throws: Never.self) { try GuardianUpdate(targets: [monitor]).validate() }
    #expect(throws: Never.self) { try GuardianUpdate(targets: [panel, monitor]).validate() }
    #expect(GuardianUpdate(targets: [panel, monitor]).panel == panel)
    #expect(GuardianUpdate(targets: [panel, monitor]).monitors == [monitor])
    #expect(throws: DisplayWorkerError.self) {
      try GuardianUpdate(targets: [panel, panel]).validate()
    }
  }
}
