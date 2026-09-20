import SoloDisplayCore
import SoloDisplayPlatform

/// Everything a menu item can ask for.
nonisolated enum MenuAction: String, CaseIterable, Equatable, Sendable {
  case selectAllMonitors, selectExternalOnly
  case retryRecovery
  case toggleLaunchAtLogin
  case toggleBrightnessKeys
  case openDisplayMonitor
  case exportDiagnostics
  case quit
}

/// Turns controller state into the panel, and nothing else. Keeping this pure means every word
/// a person can be shown can be read back in a test without launching an app.
nonisolated enum MenuModel {
  static func panel(
    _ presentation: Presentation, launchAtLogin: Bool,
    brightnessKeys: Bool = false, brightnessNeedsPermission: Bool = false
  ) -> MenuPanel {
    let chosenOff = presentation.wantsInternalOff
    let working = presentation.working
    let notRunning = presentation.unavailability == .notRunning
    // Only a Mac with no built-in display, or an app that could not start, makes an arrangement
    // unpickable. Everything else, an unplugged monitor included, is a matter of when.
    let impossible = notRunning || presentation.unavailability == .noConfirmedPanel
    return MenuPanel(
      allMonitors: .init(
        title: "All Monitors", action: .selectAllMonitors, isSelected: !chosenOff,
        isActive: !presentation.panelOff, isEnabled: !notRunning,
        isPending: !chosenOff && working, internalLit: true, externalLit: true
      ),
      externalOnly: .init(
        title: "External Only", action: .selectExternalOnly, isSelected: chosenOff,
        isActive: presentation.panelOff, isEnabled: !impossible,
        isPending: chosenOff && working, internalLit: false, externalLit: true
      ),
      reality: reality(presentation),
      alert: alert(presentation),
      launchAtLogin: .init(
        title: "Launch at Login", action: .toggleLaunchAtLogin, isOn: launchAtLogin
      ),
      brightnessKeys: .init(
        title: "Brightness Keys", action: .toggleBrightnessKeys, isOn: brightnessKeys,
        isBlocked: brightnessKeys && brightnessNeedsPermission
      ),
      commands: [
        .init(title: "Diagnostics…", action: .openDisplayMonitor),
        .init(title: "Quit SoloDisplay", action: .quit)
      ],
      glyph: glyph(presentation),
      statusDescription: status(presentation)
    )
  }

  /// What is true right now, as opposed to what was chosen, including why a choice is waiting.
  /// A monitor turned off for showing another computer is said first: it is the least expected
  /// thing on the screen, and nothing else here explains it.
  static func reality(_ presentation: Presentation) -> String {
    if presentation.suppressedMonitors == 1 {
      return "A monitor showing another computer is turned off."
    }
    if presentation.suppressedMonitors > 1 {
      return "\(presentation.suppressedMonitors) monitors showing another computer are turned off."
    }
    if presentation.panelOff {
      return presentation.working
        ? "Turning your laptop screen back on." : "Your laptop screen is off."
    }
    if let blocker = presentation.unavailability,
       blocker == .noConfirmedPanel || blocker == .notRunning {
      return reason(blocker)
    }
    if !presentation.wantsInternalOff {
      return "Your laptop screen stays on."
    }
    if let blocker = presentation.unavailability, blocker != .settling {
      return blocker == .noNativeExternal ? "Waiting for a monitor." : reason(blocker)
    }
    return "Turning your laptop screen off."
  }

  /// Only a problem that lasts raises an alert. Work in progress shows on the tile and the icon.
  static func alert(_ presentation: Presentation) -> MenuPanel.Alert? {
    guard let trouble = presentation.trouble else { return nil }
    return .init(
      severity: .attention, title: title(trouble), detail: reason(trouble), retry: .retryRecovery
    )
  }

  /// The menu bar icon, read in the same order as `status`, so the two cannot disagree.
  static func glyph(_ presentation: Presentation) -> MenuGlyph {
    if presentation.trouble != nil || presentation.unavailability == .notRunning {
      return .attention
    }
    if presentation.working
      || (presentation.wantsInternalOff && presentation.unavailability == .settling) {
      return .working
    }
    return presentation.panelOff ? .externalOnly : .allMonitors
  }

  static func status(_ presentation: Presentation) -> String {
    if let trouble = presentation.trouble {
      return title(trouble)
    }
    if presentation.working {
      return "Working…"
    }
    if presentation.panelOff {
      return "Your laptop screen is off"
    }
    return presentation.canDisableNow
      ? "Ready to switch to External Only" : "External Only is not available right now"
  }

  static func reason(_ unavailability: Unavailability) -> String {
    switch unavailability {
    case .noObservation: "Checking your displays."
    case .noConfirmedPanel: "This Mac has no built-in display to turn off."
    case .lidClosed: "Open the lid. macOS controls your laptop screen while it is closed."
    case .notAwake: "Waiting for your Mac to wake up fully."
    case .sessionNotForeground: "Another user is logged in and in front."
    case .noNativeExternal: "Connect a monitor directly to this Mac."
    case .monitorShowsAnotherMachine: "Set your monitor's input back to this Mac."
    case .unsupportedTopology: "SoloDisplay has not been tested with this display arrangement."
    case .settling: "Just a moment."
    case .notRunning: "SoloDisplay could not start. Quit it and open it again."
    }
  }

  static func title(_ trouble: Trouble) -> String {
    switch trouble {
    case .stillTrying: "Having trouble changing your laptop screen"
    case .recordNotSaved: "Could not save a safety record"
    case .recordUnresolved: "A record from an earlier run needs attention"
    case .preferencesNotSaved: "Could not save your choice"
    }
  }

  static func reason(_ trouble: Trouble) -> String {
    switch trouble {
    case .stillTrying:
      "SoloDisplay keeps trying on its own. Try Again tries right away."
    case .recordNotSaved:
      "SoloDisplay needs it before turning your laptop screen off, and keeps trying."
    case .recordUnresolved:
      "SoloDisplay cannot match it to your laptop screen. Close and open the lid, then choose Try Again."
    case .preferencesNotSaved:
      "Your choice is active now but may not survive a restart."
    }
  }
}
