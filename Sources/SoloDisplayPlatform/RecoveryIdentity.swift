import SoloDisplayCore

/// Whether a restore may be addressed to a target right now, must wait, or must never be.
public enum RecoveryReadiness: Equatable, Sendable { case ready, waiting, blocked }

/// Evidence about a target now, distinct from a record written before suppression.
public enum RecoveryIdentity {
  public static func readiness(
    _ reading: PlatformReading, target: PanelTarget,
    ownedTarget: PanelTarget? = nil
  ) -> RecoveryReadiness {
    // A positively different identity is not a temporary lifecycle condition.
    if let boot = reading.bootID, boot != target.bootID {
      return .blocked
    }
    if let login = reading.loginID, login != target.loginID {
      return .blocked
    }
    guard reading.enumerationError == nil else { return .waiting }
    guard (try? checkCurrentDisplays(reading.displays, target: target)) != nil else {
      return .blocked
    }
    // The lid rule is about the laptop panel, whose restoration would be invisible and undone
    // again with the lid shut. A monitor must not wait on it: with the lid closed that monitor
    // may be the only screen there is.
    guard reading.bootID != nil, reading.loginID != nil,
          reading.foregroundSession == .yes,
          target.kind != .builtIn || reading.lid == .open
    else { return .waiting }
    if !reading.displays.isEmpty && reading.displays.allSatisfy(\.asleep) {
      return .waiting
    }
    if let current = reading.displays.first(where: { $0.id == target.displayID }) {
      if current.asleep {
        return .waiting
      }
      return current.uuidResolvedID == target.displayID ? .ready : .waiting
    }
    return ownedTarget == target ? .ready : .waiting
  }

  /// An absent panel is usable only when a live process that turned it off asks. A cold record
  /// is an obligation to reconcile, not authority to address an unresolvable ID.
  public static func authorizeRestore(
    _ reading: PlatformReading, target: PanelTarget,
    ownedTarget: PanelTarget? = nil
  ) throws {
    switch readiness(reading, target: target, ownedTarget: ownedTarget) {
    case .ready: return
    case .waiting: throw IdentityError.insufficientEvidence
    case .blocked: throw IdentityError.contradictoryTarget
    }
  }

  public static func checkCurrentDisplays(_ displays: [DisplayReading],
                                          target: PanelTarget) throws {
    // Whatever lives at the recorded ID now must be the screen that was recorded there. Display
    // IDs are reused, so a monitor that inherited one must never be changed in another's name.
    if let current = displays.first(where: { $0.id == target.displayID }) {
      guard current.builtIn == (target.kind == .builtIn), current.uuid == target.displayUUID else {
        throw IdentityError.contradictoryTarget
      }
    }
    // A built-in that is not the recorded one means the record names another Mac's panel. There
    // is no external equivalent: several externals at once are ordinary.
    guard target.kind == .builtIn else { return }
    if displays.contains(where: {
      $0.builtIn && ($0.id != target.displayID || $0.uuid != target.displayUUID)
    }) {
      throw IdentityError.contradictoryTarget
    }
  }
}

public enum IdentityError: Error, CustomStringConvertible {
  case contradictoryTarget, insufficientEvidence
  public var description: String {
    switch self {
    case .insufficientEvidence:
      "SoloDisplay cannot establish fresh authority for this display. The record was retained."
    case .contradictoryTarget:
      "Live evidence contradicts the recorded display. No change made."
    }
  }
}
