import SoloDisplayCore

/// What the menu bar icon shows. Derived from controller state like everything else the
/// interface says, so that the icon can be asserted in a test instead of drifting out of step
/// with the display it is describing.
nonisolated enum MenuGlyph: String, CaseIterable, Equatable, Sendable {
  case allMonitors, externalOnly, working, attention

  var symbolName: String {
    switch self {
    case .allMonitors: "laptopcomputer"
    case .externalOnly, .working: "display"
    case .attention: "exclamationmark.triangle"
    }
  }

  /// Only work in progress dims the button. The other states are ones the person chose and is
  /// resting in, and a dimmed icon would read as something being wrong with them.
  var dimmed: Bool {
    self == .working
  }
}

/// Everything the menu bar panel draws, and nothing else.
///
/// Equatable is load bearing rather than incidental. The protection timer can drive a refresh
/// five times a second, and this comparison is the only thing standing between that and a panel
/// that redraws under the pointer.
nonisolated struct MenuPanel: Equatable, Sendable {
  /// The two arrangements. Exactly one is chosen, always, and the choice is a stored intent
  /// rather than a reading of the hardware.
  var allMonitors: Choice
  var externalOnly: Choice
  /// What is actually true right now, in one line, including why a choice cannot take effect.
  /// Reality lives here so the tiles are free to keep meaning what the person picked.
  var reality: String
  var alert: Alert?
  var launchAtLogin: Option
  var commands: [Command]
  var glyph: MenuGlyph
  /// The words the menu bar icon carries for anyone who cannot see it.
  var statusDescription: String

  struct Choice: Equatable, Sendable {
    var title: String
    var action: MenuAction
    var isSelected: Bool
    /// Chosen and actually in effect right now. External Only can be chosen while a monitor is
    /// unplugged, and the tile has to be able to say "yes, and not yet" at the same time.
    var isActive: Bool
    var isEnabled: Bool
    /// A request toward this arrangement is still outstanding.
    var isPending: Bool
    /// Which panels the tile artwork draws lit.
    var internalLit: Bool
    var externalLit: Bool
  }

  struct Option: Equatable, Sendable {
    var title: String
    var action: MenuAction
    var isOn: Bool
  }

  struct Command: Equatable, Sendable {
    var title: String
    var action: MenuAction
  }

  enum Severity: Equatable, Sendable { case working, attention }

  /// Raised above the choices, because it is about the machine rather than about a choice.
  struct Alert: Equatable, Sendable {
    var severity: Severity
    var title: String
    var detail: String
    var retry: MenuAction?
  }

  /// Every string a person can read here, so a property can be asserted across all of them at
  /// once instead of one assertion per label going stale.
  var allStrings: [String] {
    [allMonitors, externalOnly].map(\.title)
      + [reality, launchAtLogin.title, statusDescription]
      + commands.map(\.title)
      + [alert?.title, alert?.detail].compactMap(\.self)
  }
}

extension MenuPanel {
  /// What the panel holds before the first observation arrives. Nothing is known yet, so it
  /// says so rather than claiming an arrangement it has not looked at.
  static let placeholder = MenuModel.panel(
    .init(
      mode: .automaticPaused, manualRequestActive: false, panelOwned: false,
      operationInFlight: false, pendingRecovery: false, fault: nil, unavailability: .noObservation
    ),
    launchAtLogin: false
  )
}
