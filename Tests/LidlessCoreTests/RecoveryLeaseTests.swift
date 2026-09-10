import Testing
@testable import LidlessCore

@Test func leaseRequiresMatchingLiveAcknowledgement() {
  var lease = RecoveryLease(session: "run-A", at: 0)
  #expect(!lease.protects(at: 0))
  lease.receive(.acknowledged(session: "run-B", challenge: 1), at: 10)
  lease.receive(.acknowledged(session: "run-A", challenge: 2), at: 20)
  #expect(!lease.protects(at: 20))
  lease.receive(.acknowledged(session: "run-A", challenge: 1), at: 30)
  #expect(lease.protects(at: 30))
  #expect(!lease.protects(at: 3000))
}

@Test func renewalDoesNotExtendProtectionUntilAcknowledged() {
  var lease = RecoveryLease(session: "A", at: 0)
  lease.receive(.acknowledged(session: "A", challenge: 1), at: 1)
  #expect(lease.receive(.requestRenewal, at: 1000) == [.challenge(session: "A", number: 2)])
  #expect(lease.deadline == 3000)
  // A duplicate reply to the previous challenge cannot renew the lease.
  lease.receive(.acknowledged(session: "A", challenge: 1), at: 1500)
  #expect(lease.deadline == 3000)
  lease.receive(.acknowledged(session: "A", challenge: 2), at: 2000)
  #expect(lease.deadline == 4000)
  lease.receive(.acknowledged(session: "A", challenge: 2), at: 2500)
  #expect(lease.deadline == 4000)
}

@Test(arguments: [RecoveryLease.Event.contactLost, .interrupted, .tick])
func leaseLossRequestsRestorationExactlyOnce(_ event: RecoveryLease.Event) {
  var lease = RecoveryLease(session: "A", at: 0)
  lease.receive(.acknowledged(session: "A", challenge: 1), at: 1)
  #expect(lease.receive(event, at: 3000) == [.restore])
  #expect(!lease.protects(at: 3000))
  #expect(lease.receive(event, at: 3001).isEmpty)
  lease.receive(.acknowledged(session: "A", challenge: 1), at: 3002)
  #expect(lease.phase == .restoring)
  lease.receive(.restorationVerified, at: 3003)
  #expect(lease.phase == .finished)
}

@Test func delayedReplyCannotResurrectExpiredLeaseWithoutTimer() {
  var lease = RecoveryLease(session: "A", at: 0)
  lease.receive(.acknowledged(session: "A", challenge: 1), at: 1)
  lease.receive(.requestRenewal, at: 2000)
  #expect(lease.receive(.acknowledged(session: "A", challenge: 2), at: 3000) == [.restore])
  #expect(lease.phase == .restoring)
}

@Test func earlyContactLossAndBackwardsTimeFailClosed() {
  var lease = RecoveryLease(session: "A", at: 100)
  #expect(lease.receive(.acknowledged(session: "A", challenge: 1), at: 99).isEmpty)
  #expect(!lease.protects(at: 99))
  #expect(lease.receive(.contactLost, at: 101) == [.restore])
  #expect(lease.receive(.acknowledged(session: "A", challenge: 1), at: 102).isEmpty)
  #expect(!lease.protects(at: 102))
}

@Test func takeoverRequiresDeathThenLockThenFreshAuthorization() {
  var takeover = RecoveryTakeover()
  #expect(takeover.receive(.lockAcquired).isEmpty)
  #expect(takeover.receive(.restoreAuthorized).isEmpty)
  #expect(takeover.receive(.recoveryNeeded) == [.stopWriter])
  #expect(takeover.receive(.restoreAuthorized).isEmpty)
  #expect(takeover.receive(.writerTerminationConfirmed) == [.acquireLock])
  #expect(takeover.receive(.restoreAuthorized).isEmpty)
  #expect(takeover.receive(.lockAcquired) == [.inspectOwnedTarget])
  #expect(takeover.receive(.restoreAuthorized) == [.restore])
  #expect(takeover.receive(.restoreAuthorized).isEmpty)
  #expect(takeover.receive(.restorationVerified).isEmpty)
  #expect(takeover.receive(.restoreReturned) == [.verify])
  #expect(takeover.receive(.restorationVerified) == [.clearJournal])
  #expect(takeover.phase != .finished)
  takeover.receive(.journalCleared)
  #expect(takeover.phase == .finished)
}

@Test func observedRollbackNeedsNoEnableAndFailuresRetainResponsibility() {
  var takeover = RecoveryTakeover()
  takeover.receive(.writerTerminationConfirmed)
  takeover.receive(.lockAcquired)
  #expect(takeover.receive(.restorationVerified) == [.clearJournal])
  takeover.receive(.failed)
  #expect(takeover.phase == .blocked)
  #expect(takeover.receive(.journalCleared).isEmpty)
  #expect(takeover.receive(.restoreAuthorized).isEmpty)
}

@Test func arbitraryTakeoverEventsNeverProduceConcurrentOrRepeatedWrites() {
  let events: [RecoveryTakeover.Event] = [
    .recoveryNeeded, .writerTerminationConfirmed, .lockAcquired, .restoreAuthorized,
    .restoreReturned, .restorationVerified, .journalCleared, .failed
  ]
  for seed in 1 ... 100 {
    var random = UInt64(seed)
    var takeover = RecoveryTakeover()
    var writes = 0
    var deathConfirmed = false
    var lockAcquiredAfterDeath = false
    for _ in 0 ..< 200 {
      random = random &* 6_364_136_223_846_793_005 &+ 1
      let event = events[Int((random >> 32) % UInt64(events.count))]
      if event == .writerTerminationConfirmed {
        deathConfirmed = true
      }
      if event == .lockAcquired, takeover.phase == .acquiringLock {
        lockAcquiredAfterDeath = deathConfirmed
      }
      let effects = takeover.receive(event)
      if effects.contains(.restore) {
        writes += 1
        #expect(deathConfirmed && lockAcquiredAfterDeath)
      }
      #expect(writes <= 1)
    }
  }
}
