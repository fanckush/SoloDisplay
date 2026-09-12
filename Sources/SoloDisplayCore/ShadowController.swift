/// Runs the real controller without an effect executor. It cannot persist or change displays.
/// The bounded effect count makes unexpected requests visible without storing raw identities.
public struct ShadowController: Sendable {
  public private(set) var state = ControllerState()
  public private(set) var observationCount: UInt64 = 0
  public private(set) var rejectedEffectCount: UInt64 = 0
  public private(set) var nextWake: Instant?

  public init() {}

  public mutating func observe(_ environment: Environment, at now: Instant) {
    guard now >= state.lastReceipt, observationCount < .max else { return }
    observationCount += 1
    receive(
      .observed(.init(sequence: observationCount, sampledAt: now, environment: environment)),
      at: now
    )
  }

  public mutating func receive(_ event: Event, at now: Instant) {
    let transition = Controller.reduce(state, event, at: now)
    state = transition.state
    for effect in transition.effects {
      switch effect {
      case let .wakeAt(instant): nextWake = instant
      case .observe, .observeAt, .exitReady: break
      default:
        if rejectedEffectCount < .max {
          rejectedEffectCount += 1
        }
      }
    }
  }

  public mutating func tick(at now: Instant) {
    if let nextWake, now >= nextWake {
      self.nextWake = nil
      receive(.tick, at: now)
    }
  }
}
