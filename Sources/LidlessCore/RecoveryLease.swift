/// A lease is bound to one live handshake, not a reusable PID or a persisted display ID.
/// The process adapter must authenticate the peer and validate the journal before acknowledging.
public struct RecoveryLease: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case awaitingAcknowledgement, protected, restoring, finished
  }

  public enum Event: Equatable, Sendable {
    case acknowledged(session: String, challenge: UInt64)
    /// The machine was suspended. Elapsed time did not give the peer a chance to answer.
    case resumed
    case requestRenewal
    case contactLost
    case interrupted
    case tick
    case restorationVerified
  }

  public enum Effect: Equatable, Sendable {
    case challenge(session: String, number: UInt64)
    case restore
  }

  public let session: String
  public let duration: Instant
  public private(set) var phase: Phase = .awaitingAcknowledgement
  public private(set) var deadline: Instant
  public private(set) var lastReceipt: Instant
  public private(set) var challenge: UInt64 = 1
  public private(set) var awaitingReply = true

  public init(session: String, at now: Instant, duration: Instant = 3_000) {
    precondition(!session.isEmpty && now >= 0 && duration > 0 && now <= .max - duration)
    self.session = session
    self.duration = duration
    deadline = now + duration
    lastReceipt = now
  }

  /// The caller sends challenge 1 at creation. A lease alone is never permission to disable:
  /// durable ownership, the writer lock, and fresh platform prerequisites are also required.
  public func protects(at now: Instant) -> Bool {
    phase == .protected && now >= lastReceipt && now < deadline
  }

  @discardableResult public mutating func receive(_ event: Event, at now: Instant) -> [Effect] {
    guard now >= lastReceipt else { return [] }
    lastReceipt = now
    guard phase != .finished else { return [] }
    if event == .restorationVerified {
      guard phase == .restoring else { return [] }
      phase = .finished
      return []
    }
    guard phase != .restoring else { return [] }
    if event == .resumed {
      guard phase == .protected, challenge < .max, now <= .max - duration else { return [] }
      deadline = now + duration
      challenge += 1
      phase = .awaitingAcknowledgement
      awaitingReply = true
      renewalDeadline = nil
      return [.challenge(session: session, number: challenge)]
    }
    // A queued acknowledgement cannot revive an expired lease, even before its timer fires.
    if now >= deadline || event == .contactLost || event == .interrupted {
      phase = .restoring
      return [.restore]
    }
    switch event {
    case .acknowledged(let session, let number):
      guard session == self.session, number == challenge, awaitingReply else { return [] }
      awaitingReply = false
      phase = .protected
    // Bound renewed validity to when the challenge was sent, not when a delayed reply arrived.
    case .requestRenewal:
      guard phase == .protected, !awaitingReply, challenge < .max,
        now <= .max - duration
      else { return [] }
      challenge += 1
      awaitingReply = true
      // The old deadline remains authoritative until the new challenge is acknowledged.
      renewalDeadline = now + duration
      return [.challenge(session: session, number: challenge)]
    default: break
    }
    if case .acknowledged = event, !awaitingReply, let renewalDeadline {
      deadline = renewalDeadline
      self.renewalDeadline = nil
    }
    return []
  }

  private var renewalDeadline: Instant?
}

/// Supervisor-side takeover ordering. Effects are requests, never proof that an action succeeded.
/// Every instance belongs to one actual child Process and one validated, durable journal.
public struct RecoveryTakeover: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case watching, stoppingWriter, acquiringLock, readyToRestore, restoring, verifying
    case clearingJournal, finished, blocked
  }
  public enum Event: Equatable, Sendable {
    case recoveryNeeded
    case writerTerminationConfirmed
    case lockAcquired
    case restoreAuthorized
    case restoreReturned
    case restorationVerified
    case journalCleared
    case failed
  }
  public enum Effect: Equatable, Sendable {
    case stopWriter, acquireLock, inspectOwnedTarget, restore, verify, clearJournal
  }
  public private(set) var phase: Phase = .watching
  public init() {}

  @discardableResult public mutating func receive(_ event: Event) -> [Effect] {
    guard phase != .finished, phase != .blocked else { return [] }
    if event == .failed {
      // Retain the journal and any acquired lock. A fresh process must reconcile them.
      phase = .blocked
      return []
    }
    switch (phase, event) {
    case (.watching, .recoveryNeeded):
      phase = .stoppingWriter
      return [.stopWriter]
    case (.watching, .writerTerminationConfirmed), (.stoppingWriter, .writerTerminationConfirmed):
      phase = .acquiringLock
      return [.acquireLock]
    case (.acquiringLock, .lockAcquired):
      phase = .readyToRestore
      return [.inspectOwnedTarget]
    case (.readyToRestore, .restoreAuthorized):
      // The adapter must validate current boot/session, live identity contradictions, and power.
      phase = .restoring
      return [.restore]
    case (.restoring, .restoreReturned):
      // Even an API error may have changed the display. Verify rather than issuing another write.
      phase = .verifying
      return [.verify]
    case (.readyToRestore, .restorationVerified), (.verifying, .restorationVerified):
      phase = .clearingJournal
      return [.clearJournal]
    case (.clearingJournal, .journalCleared):
      phase = .finished
      return []
    default: return []
    }
  }
}
