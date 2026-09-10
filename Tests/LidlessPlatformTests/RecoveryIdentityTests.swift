import LidlessCore
import Testing
@testable import LidlessPlatform

private let owned = PanelTarget(displayID: 1, displayUUID: "panel", bootID: "boot", loginID: 42)

@Test func handoffAllowsAnAbsentOwnedPanelOnlyForActualParentAndMatchingSession() throws {
  let journal = RecoveryJournal(target: owned, scope: "app", ownerPID: 555)
  #expect(throws: Never.self) {
    try RecoveryIdentity.authorizeHandoff(
      journal: journal, bootID: "boot", loginID: 42, parentPID: 555, displays: []
    )
  }
  #expect(throws: (any Error).self) {
    try RecoveryIdentity.authorizeHandoff(
      journal: journal, bootID: "boot", loginID: 42, parentPID: 556, displays: []
    )
  }
  #expect(throws: (any Error).self) {
    try RecoveryIdentity.authorizeHandoff(
      journal: journal, bootID: "other", loginID: 42, parentPID: 555, displays: []
    )
  }
}

@Test func aReusedDisplayIDCannotAuthorizeHandoff() {
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
