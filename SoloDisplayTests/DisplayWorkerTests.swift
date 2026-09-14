import Foundation
import SoloDisplayCore
import SoloDisplayPlatform
import Testing
@testable import SoloDisplay

struct DisplayWorkerTests {
  private let panel = PanelTarget(
    displayID: 1, displayUUID: "panel-uuid", bootID: "boot", loginID: 42
  )

  private func reading(panelPresent: Bool = true, lid: Lid = .open) throws -> PlatformReading {
    var displays = [
      #"{"id":5,"uuid":"external","uuidResolvedID":5,"builtIn":false,"active":true,"online":true,"asleep":false,"mirrored":false,"width":1920,"height":1080,"originX":0,"originY":0,"modeAvailable":true,"transport":"native"}"#
    ]
    if panelPresent {
      displays.insert(
        #"{"id":1,"uuid":"panel-uuid","uuidResolvedID":1,"builtIn":true,"active":true,"online":true,"asleep":false,"mirrored":false,"width":1512,"height":982,"originX":0,"originY":0,"modeAvailable":true,"transport":"unclassified"}"#,
        at: 0
      )
    }
    let json = #"""
    {"schemaVersion":1,"osVersion":"synthetic","monotonicMilliseconds":100,"lid":"\#(lid.rawValue)",
     "bootID":"boot","loginID":42,"foregroundSession":"yes","backendValidated":false,
     "limitations":[],"transportEvidence":[],"displays":[\#(displays.joined(separator: ","))]}
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
    let request = GuardianRequest(parentPID: 321, target: panel)
    #expect(throws: Never.self) { try request.validate(actualParentPID: 321) }
    #expect(throws: DisplayWorkerError.self) { try request.validate(actualParentPID: 1) }
    var incomplete = request
    incomplete.target.bootID = ""
    #expect(throws: DisplayWorkerError.self) { try incomplete.validate(actualParentPID: 321) }
  }
}
