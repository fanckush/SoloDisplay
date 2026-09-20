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
  /// Readings in a row that must leave the panel unreadable before acting on that alone. Longer
  /// than `dangerReadings`, because a panel is briefly unreadable during any ordinary
  /// reconfiguration and the app is the one that should handle those.
  public static let unreadableReadings = 5

  /// What this process has seen in a row. A panel that cannot be read and a panel that is off
  /// with nothing to look at are different dangers and are counted apart.
  public struct Streaks: Equatable, Sendable {
    public var danger = 0
    public var unreadable = 0
    public init() {}
  }

  public static func decide(
    _ environment: Environment, appAlive: Bool, streaks: inout Streaks
  ) -> GuardianAction {
    switch environment.panelState {
    case .unknown:
      // The guardian exists only because this panel was owed. With no way to read it, waiting
      // for evidence that may never come is how a screen stays off until the Mac is restarted,
      // and turning on a panel that is already on costs nothing. The app being gone is certainty
      // enough on its own; while it is still there, it gets a few readings to sort this out.
      streaks.danger = 0
      guard appAlive else { return .restore }
      streaks.unreadable += 1
      return streaks.unreadable >= unreadableReadings ? .restore : .wait
    case .enabled:
      streaks = .init()
      return appAlive ? .wait : .finish
    case .disabled:
      streaks.unreadable = 0
      guard appAlive else { return .restore }
      guard environment.nativeExternalAvailable != .yes else {
        streaks.danger = 0
        return .wait
      }
      streaks.danger += 1
      return streaks.danger >= dangerReadings ? .restore : .wait
    }
  }
}
