import AppIntents

/// The two arrangements, named the way the menu names them.
nonisolated enum Arrangement: String, AppEnum {
  case allMonitors, externalOnly

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Arrangement"
  static let caseDisplayRepresentations: [Arrangement: DisplayRepresentation] = [
    .allMonitors: "All Monitors",
    .externalOnly: "External Only"
  ]
}

/// Why a shortcut could not change the arrangement, in the words the menu would use.
nonisolated struct ShortcutRefusal: Error, CustomLocalizedStringResourceConvertible {
  let reason: String

  var localizedStringResource: LocalizedStringResource {
    "\(reason)"
  }
}

/// What a shortcut does, decided from the panel the menu is showing. Kept pure so it can be
/// asserted in a test without the Shortcuts app.
nonisolated enum ShortcutModel {
  /// A toggle moves away from what is chosen, not from what is on screen: External Only can be
  /// chosen while no monitor is connected, and toggling then means going back to All Monitors.
  static func toggled(from panel: MenuPanel) -> Arrangement {
    panel.externalOnly.isSelected ? .allMonitors : .externalOnly
  }

  /// The same action the tile sends, or the reason the tile is unavailable.
  static func action(for arrangement: Arrangement, in panel: MenuPanel) throws -> MenuAction {
    let choice = arrangement == .allMonitors ? panel.allMonitors : panel.externalOnly
    guard choice.isEnabled else { throw ShortcutRefusal(reason: panel.reality) }
    return choice.action
  }
}

/// Connects the intents to the running menu bar app. Left unset in a guardian, a worker and the
/// tests, where there is no menu to act on.
enum ShortcutBridge {
  static var panel: (() -> MenuPanel)?
  static var perform: ((MenuAction) -> Void)?

  static func choose(_ arrangement: Arrangement) async throws {
    let app = try await ready()
    try app.perform(ShortcutModel.action(for: arrangement, in: app.panel()))
  }

  static func toggle() async throws -> Arrangement {
    let app = try await ready()
    let target = ShortcutModel.toggled(from: app.panel())
    try app.perform(ShortcutModel.action(for: target, in: app.panel()))
    return target
  }

  /// Shortcuts may launch the app to run an intent, and the menu comes up a moment later.
  private static func ready() async throws -> (
    panel: () -> MenuPanel, perform: (MenuAction) -> Void
  ) {
    var waited = 0
    while panel == nil, waited < 20 {
      try await Task.sleep(for: .milliseconds(100))
      waited += 1
    }
    guard let panel, let perform else {
      throw ShortcutRefusal(reason: "SoloDisplay is not running.")
    }
    return (panel, perform)
  }
}

struct SetArrangementIntent: AppIntent {
  static let title: LocalizedStringResource = "Set Arrangement"
  static let description = IntentDescription(
    "Chooses All Monitors or External Only, the same as picking a tile in the SoloDisplay menu."
  )

  @Parameter(title: "Arrangement")
  var arrangement: Arrangement

  static var parameterSummary: some ParameterSummary {
    Summary("Switch SoloDisplay to \(\.$arrangement)")
  }

  init() {}

  init(arrangement: Arrangement) {
    self.arrangement = arrangement
  }

  func perform() async throws -> some IntentResult {
    try await ShortcutBridge.choose(arrangement)
    return .result()
  }
}

struct ToggleArrangementIntent: AppIntent {
  static let title: LocalizedStringResource = "Toggle Arrangement"
  static let description = IntentDescription(
    "Switches between All Monitors and External Only."
  )

  func perform() async throws -> some IntentResult & ReturnsValue<Arrangement> {
    try await .result(value: ShortcutBridge.toggle())
  }
}

/// Offered in Shortcuts and Spotlight as soon as the app is installed, with no setup. A keyboard
/// shortcut can be given to any of them from the Shortcuts app.
struct SoloDisplayShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ToggleArrangementIntent(),
      phrases: ["Toggle \(.applicationName)"],
      shortTitle: "Toggle Arrangement",
      systemImageName: "rectangle.2.swap"
    )
    AppShortcut(
      intent: SetArrangementIntent(),
      phrases: ["Switch \(.applicationName) to \(\.$arrangement)"],
      shortTitle: "Set Arrangement",
      systemImageName: "display"
    )
  }
}
