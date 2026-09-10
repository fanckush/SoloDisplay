/// Platform evidence can defer a recovery without weakening identity requirements.
public enum RecoveryReadiness: Equatable, Sendable { case ready, waiting, blocked }

/// One supervised recovery after writer death and lock acquisition. Waiting consumes no
/// attempts. A returned call is verified, never blindly repeated. No effect launches a writer.
public struct RecoveryContinuation: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case waiting, writing, verifying, clearing, finished, blocked
  }

  public enum Action: Equatable, Sendable { case none, restore, clear }
  public private(set) var phase: Phase = .waiting
  private var verificationDeadline: Instant?
  public init() {}

  public mutating func observe(
    readiness: RecoveryReadiness, restored: Fact,
    at now: Instant
  ) -> Action {
    guard phase == .waiting || phase == .verifying else { return .none }
    if readiness == .blocked {
      phase = .blocked
      return .none
    }
    guard readiness == .ready else {
      verificationDeadline = nil
      return .none
    }
    if restored == .yes {
      phase = .clearing
      return .clear
    }
    if phase == .waiting {
      phase = .writing
      return .restore
    }
    if verificationDeadline == nil {
      verificationDeadline = now + 3000
    }
    if now >= verificationDeadline! {
      phase = .blocked
    }
    return .none
  }

  public mutating func writeDeferred() {
    if phase == .writing {
      phase = .waiting
    }
  }

  public mutating func writeReturned() {
    if phase == .writing {
      phase = .verifying
      verificationDeadline = nil
    }
  }

  public mutating func journalCleared(succeeded: Bool) {
    if phase == .clearing {
      phase = succeeded ? .finished : .blocked
    }
  }

  public mutating func block() {
    if phase != .finished {
      phase = .blocked
    }
  }
}
