import LidlessCore

/// Evidence about a target now, distinct from ownership established before suppression.
public enum RecoveryIdentity {
  public static func checkCurrentDisplays(_ displays: [DisplayReading], target: PanelTarget) throws
  {
    if let current = displays.first(where: { $0.id == target.displayID }) {
      guard current.builtIn && current.uuid == target.displayUUID else {
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
    guard parentPID > 1 && parentPID == journal.ownerPID else {
      throw IdentityError.unrelatedParent
    }
    try checkCurrentDisplays(displays, target: journal.target)
  }
}

public enum IdentityError: Error, CustomStringConvertible {
  case contradictoryTarget, unrelatedParent
  public var description: String {
    switch self {
    case .contradictoryTarget:
      "Live evidence contradicts the journaled built-in target. No change made."
    case .unrelatedParent:
      "Cooperative recovery requires the actual live writer as parent. No change made."
    }
  }
}
