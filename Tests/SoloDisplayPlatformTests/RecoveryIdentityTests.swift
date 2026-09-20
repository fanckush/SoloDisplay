import SoloDisplayCore
import Testing
@testable import SoloDisplayPlatform

private let owned = PanelTarget(displayID: 1, displayUUID: "panel", bootID: "boot", loginID: 42)

@Test func aReusedDisplayIDCannotStandInForThePanel() {
  let impostor = DisplayReading(
    id: 1, uuid: "external", uuidResolvedID: 1, builtIn: false, active: true,
    online: true, asleep: false, mirrored: false, mirrorSourceID: nil,
    width: 1920, height: 1080, originX: 0, originY: 0, modeAvailable: true
  )
  #expect(throws: (any Error).self) {
    try RecoveryIdentity.checkCurrentDisplays([impostor], target: owned)
  }
}

@Test func aNewInternalIdentityPreventsRecoveryOfTheOldID() {
  let replacement = DisplayReading(
    id: 2, uuid: "new-panel", uuidResolvedID: 2, builtIn: true, active: true,
    online: true, asleep: false, mirrored: false, mirrorSourceID: nil,
    width: 1512, height: 982, originX: 0, originY: 0, modeAvailable: true
  )
  #expect(throws: (any Error).self) {
    try RecoveryIdentity.checkCurrentDisplays([replacement], target: owned)
  }
}

private let monitor = PanelTarget(
  displayID: 4, displayUUID: "dell", bootID: "boot", loginID: 42,
  kind: .external, controller: "dispext0"
)

private func display(
  id: UInt32, uuid: String, builtIn: Bool, asleep: Bool = false
) -> DisplayReading {
  .init(
    id: id, uuid: uuid, uuidResolvedID: id, builtIn: builtIn, active: true, online: true,
    asleep: asleep, mirrored: false, mirrorSourceID: nil, width: 1920, height: 1080,
    originX: 0, originY: 0, modeAvailable: true
  )
}

private func reading(
  _ displays: [DisplayReading], lid: Lid = .open
) -> PlatformReading {
  .init(
    osVersion: "27.0", monotonicMilliseconds: 0, enumerationError: nil, displays: displays,
    lid: lid, bootID: "boot", loginID: 42, foregroundSession: .yes, privateSymbol: nil,
    limitations: []
  )
}

/// A monitor is recovered from different evidence than the laptop panel: it can legitimately sit
/// beside a built-in, and it is not always there to be looked up again.
@Test func aMonitorIsNotContradictedByTheLaptopPanelBesideIt() throws {
  let panel = display(id: 1, uuid: "panel", builtIn: true)
  let dell = display(id: 4, uuid: "dell", builtIn: false)
  try RecoveryIdentity.checkCurrentDisplays([panel, dell], target: monitor)
  // The same arrangement contradicts a built-in target that names some other Mac's panel.
  let otherMac = PanelTarget(
    displayID: 9, displayUUID: "another-panel", bootID: "boot", loginID: 42
  )
  #expect(throws: (any Error).self) {
    try RecoveryIdentity.checkCurrentDisplays([panel, dell], target: otherMac)
  }
}

@Test func aReusedDisplayIDCannotStandInForAMonitorEither() {
  let impostor = display(id: 4, uuid: "someone-else", builtIn: false)
  #expect(throws: (any Error).self) {
    try RecoveryIdentity.checkCurrentDisplays([impostor], target: monitor)
  }
  // A built-in that inherited the monitor's ID is a contradiction too.
  #expect(throws: (any Error).self) {
    try RecoveryIdentity.checkCurrentDisplays(
      [display(id: 4, uuid: "dell", builtIn: true)], target: monitor
    )
  }
}

/// The lid rule protects the laptop panel from being restored where nobody could see it. With the
/// lid shut a monitor may be the only screen there is, so it must not wait on the lid.
@Test func restoringAMonitorDoesNotWaitForAnOpenLid() {
  let closed = reading([display(id: 1, uuid: "panel", builtIn: true)], lid: .closed)
  #expect(
    RecoveryIdentity.readiness(closed, target: monitor, ownedTarget: monitor) == .ready
  )
  #expect(RecoveryIdentity.readiness(closed, target: owned, ownedTarget: owned) == .waiting)
}
