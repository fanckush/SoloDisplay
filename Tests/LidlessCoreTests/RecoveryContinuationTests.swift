import Testing
@testable import LidlessCore

@Test func supervisedRecoveryWaitsWithoutLosingItsWriteOrClearObligation() {
  var recovery = RecoveryContinuation()
  for now: Instant in [0, 10000, 100_000] {
    #expect(recovery.observe(readiness: .waiting, restored: .unknown, at: now) == .none)
    #expect(recovery.phase == .waiting)
  }
  #expect(recovery.observe(readiness: .ready, restored: .unknown, at: 100_001) == .restore)
  recovery.writeDeferred() // The lid closed after dispatch, before any API call.
  #expect(recovery.phase == .waiting)
  #expect(recovery.observe(readiness: .ready, restored: .unknown, at: 100_002) == .restore)
  recovery.writeReturned()
  #expect(recovery.observe(readiness: .ready, restored: .unknown, at: 100_003) == .none)
  #expect(recovery.observe(readiness: .waiting, restored: .unknown, at: 100_004) == .none)
  #expect(recovery.observe(readiness: .waiting, restored: .unknown, at: 200_000) == .none)
  #expect(recovery.phase == .verifying)
  #expect(recovery.observe(readiness: .ready, restored: .unknown, at: 200_001) == .none)
  #expect(recovery.observe(readiness: .ready, restored: .yes, at: 200_500) == .clear)
  recovery.journalCleared(succeeded: true)
  #expect(recovery.phase == .finished)
  #expect(recovery.observe(readiness: .ready, restored: .unknown, at: 201_000) == .none)
}

@Test func contradictionAndFailedVerificationNeverBecomeAnotherWrite() {
  var contradicted = RecoveryContinuation()
  #expect(contradicted.observe(readiness: .blocked, restored: .yes, at: 0) == .none)
  #expect(contradicted.phase == .blocked)
  var unverified = RecoveryContinuation()
  #expect(unverified.observe(readiness: .ready, restored: .unknown, at: 0) == .restore)
  unverified.writeReturned()
  _ = unverified.observe(readiness: .ready, restored: .unknown, at: 1)
  #expect(unverified.observe(readiness: .ready, restored: .no, at: 3001) == .none)
  #expect(unverified.phase == .blocked)
}

@Test func anAlreadyRestoredPanelNeedsOnlyAConfirmedJournalClear() {
  var recovery = RecoveryContinuation()
  #expect(recovery.observe(readiness: .ready, restored: .yes, at: 0) == .clear)
  recovery.journalCleared(succeeded: false)
  #expect(recovery.phase == .blocked)
}
