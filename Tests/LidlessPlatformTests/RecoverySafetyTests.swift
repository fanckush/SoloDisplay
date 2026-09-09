import LidlessCore
import Testing
@testable import LidlessPlatform

private let recoveryPanel = PanelTarget(displayID: 1, displayUUID: "panel", bootID: "boot", loginID: 7)
private func recoveryReading() -> PlatformReading {
  .init(osVersion: "test", monotonicMilliseconds: 0, displays: [], lid: .open,
    bootID: "boot", loginID: 7, foregroundSession: .yes, privateSymbol: nil, limitations: [])
}

@Test func absentTargetNeedsLiveOwnershipAndSuccessfulEnumeration() throws {
  var reading = recoveryReading()
  let owned = Ownership(target: recoveryPanel, operationID: 1)
  #expect(throws: (any Error).self) {
    try RecoveryIdentity.authorizeRestore(reading, target: recoveryPanel)
  }
  try RecoveryIdentity.authorizeRestore(reading, target: recoveryPanel, liveOwnership: owned)
  reading.enumerationError = 1
  #expect(throws: (any Error).self) {
    try RecoveryIdentity.authorizeRestore(reading, target: recoveryPanel, liveOwnership: owned)
  }
}

@Test func closedLidAndForeignSessionCannotAuthorizeARecoveryWrite() {
  var reading = recoveryReading()
  let owned = Ownership(target: recoveryPanel, operationID: 1)
  reading.lid = .closed
  #expect(throws: (any Error).self) {
    try RecoveryIdentity.authorizeRestore(reading, target: recoveryPanel, liveOwnership: owned)
  }
  reading.lid = .open
  reading.loginID = 8
  #expect(throws: (any Error).self) {
    try RecoveryIdentity.authorizeRestore(reading, target: recoveryPanel, liveOwnership: owned)
  }
}

@Test func transportCorrelationRejectsBorrowedOrContradictoryIdentity() {
  typealias Identity = DisplayTransportClassifier.Identity
  let native = Identity(vendor: 4268, model: 17020, serial: 123)
  let other = Identity(vendor: 4268, model: 17020, serial: 456)
  #expect(DisplayTransportClassifier.uniqueService(for: native,
    displays: [native], services: [native]) == 0)
  #expect(DisplayTransportClassifier.uniqueService(for: other,
    displays: [native, other], services: [native]) == nil)
  #expect(DisplayTransportClassifier.uniqueService(for: native,
    displays: [native, native], services: [native]) == nil)
  #expect(DisplayTransportClassifier.uniqueService(for: native,
    displays: [native], services: [native, native]) == nil)
}
