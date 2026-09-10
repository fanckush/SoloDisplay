import SoloDisplayCore

/// Evidence about a target now, distinct from ownership established before suppression.
public enum RecoveryIdentity {
  public static func readiness(
    _ reading: PlatformReading, target: PanelTarget,
    liveOwnership: Ownership? = nil
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
    guard reading.bootID != nil, reading.loginID != nil,
          reading.foregroundSession == .yes, reading.lid == .open
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
    return liveOwnership?.target == target ? .ready : .waiting
  }

  /// Absence is usable only for an operation witnessed by this live process pairing. A cold
  /// journal is an obligation to reconcile, not authority to address an unresolvable ID.
  public static func authorizeRestore(
    _ reading: PlatformReading, target: PanelTarget,
    liveOwnership: Ownership? = nil
  ) throws {
    switch readiness(reading, target: target, liveOwnership: liveOwnership) {
    case .ready: return
    case .waiting: throw IdentityError.insufficientEvidence
    case .blocked: throw IdentityError.contradictoryTarget
    }
  }

  public static func checkCurrentDisplays(_ displays: [DisplayReading],
                                          target: PanelTarget) throws {
    if let current = displays.first(where: { $0.id == target.displayID }) {
      guard current.builtIn, current.uuid == target.displayUUID else {
        throw IdentityError.contradictoryTarget
      }
    }
    if displays.contains(where: {
      $0.builtIn && ($0.id != target.displayID || $0.uuid != target.displayUUID)
    }) {
      throw IdentityError.contradictoryTarget
    }
  }

  /// Only the actual child of a live owner may use the experimental cooperative handoff.
  /// An absent target is expected here; this is not permission to guess a target after a crash.
  public static func authorizeHandoff(
    journal: RecoveryJournal, bootID: String?, loginID: UInt32?,
    parentPID: Int32, displays: [DisplayReading]
  ) throws {
    try journal.validate(bootID: bootID, loginID: loginID)
    guard parentPID > 1, parentPID == journal.ownerPID else {
      throw IdentityError.unrelatedParent
    }
    try checkCurrentDisplays(displays, target: journal.target)
  }
}

public enum IdentityError: Error, CustomStringConvertible {
  case contradictoryTarget, unrelatedParent, insufficientEvidence
  public var description: String {
    switch self {
    case .insufficientEvidence:
      "SoloDisplay cannot establish fresh authority for this internal panel. The recovery record was retained."
    case .contradictoryTarget:
      "Live evidence contradicts the journaled built-in target. No change made."
    case .unrelatedParent:
      "Cooperative recovery requires the actual live writer as parent. No change made."
    }
  }
}
