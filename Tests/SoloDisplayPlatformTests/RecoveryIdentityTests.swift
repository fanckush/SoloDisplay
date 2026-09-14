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
