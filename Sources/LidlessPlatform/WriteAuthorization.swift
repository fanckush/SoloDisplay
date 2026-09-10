import LidlessCore
import Synchronization

/// Invalidates work queued before a sleep transition. Re-enabling the gate creates a new
/// generation, so an old queued request cannot become valid merely because the Mac woke later.
public final class WriteAvailability: Sendable {
  public struct Grant: Sendable {
    fileprivate let generation: UInt64
  }

  private struct State {
    var awake: Bool
    var generation: UInt64 = 0
  }

  private let value: Mutex<State>

  public init(awake: Bool) {
    value = Mutex(.init(awake: awake))
  }

  public func update(awake: Bool) {
    value.withLock { state in
      if state.awake, !awake {
        state.generation &+= 1
      }
      state.awake = awake
    }
  }

  public func grant() -> Grant? {
    value.withLock { $0.awake ? Grant(generation: $0.generation) : nil }
  }

  public func permits(_ grant: Grant) -> Bool {
    value.withLock { $0.awake && $0.generation == grant.generation }
  }
}

/// Published by the authenticated protocol adapter, checked on the writer lane. Keeping the
/// full lease preserves its original expiry even if the main event loop stops running.
public final class ProtectionAuthorization: Sendable {
  private let value = Mutex<ControllerProtection?>(nil)
  public init() {}
  public func update(_ protection: ControllerProtection) {
    value.withLock { $0 = protection }
  }

  public func permits(_ ownership: Ownership, at now: Instant) -> Bool {
    value.withLock { $0?.ownership == ownership && $0?.protects(at: now) == true }
  }
}

/// The commit point between cancellable queued work and an in-flight platform call. No lock
/// is held across the OS call: a timeout is not cancellation and the UI must remain responsive.
final class DisablePermit: Sendable {
  struct Grant: Sendable {
    let operationID: UInt64
    let target: PanelTarget
    let expires: Instant
  }

  private let value = Mutex<Grant?>(nil)
  func update(_ state: ControllerState, at now: Instant) {
    value.withLock { grant in
      guard state.wantsOff, state.protectionAvailable, let op = state.operation,
            op.kind == .disable, op.phase == .submitted, let sample = state.observation,
            sample.environment.prerequisitesMet, now >= sample.sampledAt
      else { grant = nil; return }
      grant = .init(operationID: op.id, target: op.target,
                    expires: min(op.deadline, sample.sampledAt + state.policy.evidenceLifetime))
    }
  }

  func consume(operationID: UInt64, target: PanelTarget, at now: Instant) -> Bool {
    value.withLock { grant in
      guard let current = grant, current.operationID == operationID, current.target == target,
            now < current.expires else { return false }
      grant = nil
      return true
    }
  }
}
