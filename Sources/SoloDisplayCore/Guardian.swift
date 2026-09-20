public enum GuardianAction: Equatable, Sendable {
  case wait
  /// Turn the laptop screen back on.
  case restore
  /// The screen is on and the app is gone: nothing is owed. Clear the record and exit.
  case finish
}

/// What the guardian does with one reading. It acts on danger or on certainty, never on time:
/// danger is the laptop screen off with no usable monitor, certainty is the app process gone.
/// It never stops the app. A hung or slow app with a monitor connected is not dangerous.
public enum GuardianPolicy {
  /// Monitors this app turned off are never danger: they are only ever turned off while another
  /// screen is left, so the person can still see. They are restored on certainty alone, which is
  /// the app being gone, and never on a monitor's own account: this process must not do DDC,
  /// because a second process on the same wire corrupts both.
  public static func monitorsToRestore(
    _ monitors: [PanelTarget], appAlive: Bool, discharged: Set<UInt32>
  ) -> [PanelTarget] {
    guard !appAlive else { return [] }
    return monitors.filter { !discharged.contains($0.displayID) }
  }

  /// Readings in a row that must show danger before acting, so one odd reading during a
  /// reconfiguration the app is already handling does not start a second writer.
  public static let dangerReadings = 2

  public static func decide(
    _ environment: Environment, appAlive: Bool, dangerStreak: inout Int
  ) -> GuardianAction {
    switch environment.panelState {
    case .unknown:
      return .wait
    case .enabled:
      dangerStreak = 0
      return appAlive ? .wait : .finish
    case .disabled:
      guard appAlive else { return .restore }
      guard environment.nativeExternalAvailable != .yes else {
        dangerStreak = 0
        return .wait
      }
      dangerStreak += 1
      return dangerStreak >= dangerReadings ? .restore : .wait
    }
  }
}
