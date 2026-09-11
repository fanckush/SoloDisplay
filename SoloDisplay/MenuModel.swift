import SoloDisplayCore
import SoloDisplayPlatform

/// Everything a menu item can ask for. A production action never reaches a lab command.
nonisolated enum MenuAction: String, CaseIterable, Equatable, Sendable {
  case selectAllMonitors, selectExternalOnly
  case retryRecovery
  case toggleLaunchAtLogin
  case openDisplayMonitor
  case exportDiagnostics
  case quit
}

/// Turns controller state into the panel, and nothing else. Keeping this pure means the wording
/// of every refusal can be tested without launching an app or touching a display.
nonisolated enum MenuModel {
  /// The panel, as a pure function of controller state. Every word a person can be shown here,
  /// including every refusal, is decided in this file and can be read back in a test without
  /// launching an app or touching a display.
  static func panel(_ presentation: Presentation, launchAtLogin: Bool) -> MenuPanel {
    let chosenOff = presentation.wantsInternalOff
    let busy = presentation.operationInFlight
    // Only two things make an arrangement genuinely unpickable: a Mac with no built-in display
    // to turn off, and an app on its way out. Everything else, an unplugged monitor included,
    // is a matter of when rather than whether, so the choice stands and the tile says it is
    // waiting. A greyed tile would claim the setting cannot even be held, which is false.
    let impossible = presentation.unavailability == .noConfirmedPanel
      || presentation.unavailability == .shuttingDown
    return MenuPanel(
      allMonitors: .init(
        title: "All Monitors", action: .selectAllMonitors, isSelected: !chosenOff,
        isActive: !presentation.panelOwned, isEnabled: !busy,
        isPending: !chosenOff && busy, internalLit: true, externalLit: true
      ),
      externalOnly: .init(
        title: "External Only", action: .selectExternalOnly, isSelected: chosenOff,
        isActive: presentation.panelOwned, isEnabled: !busy && !impossible,
        isPending: chosenOff && busy, internalLit: false, externalLit: true
      ),
      reality: reality(presentation),
      alert: alert(presentation),
      launchAtLogin: .init(
        title: "Launch at Login", action: .toggleLaunchAtLogin, isOn: launchAtLogin
      ),
      commands: [
        .init(title: "Diagnostics…", action: .openDisplayMonitor),
        .init(title: "Quit SoloDisplay", action: .quit)
      ],
      glyph: glyph(presentation),
      statusDescription: status(presentation)
    )
  }

  /// What is true right now, as opposed to what was chosen. This is also where a blocked choice
  /// explains itself, so the explanation sits with the thing it blocks instead of becoming a
  /// heading the person has to read before they have asked for anything.
  static func reality(_ presentation: Presentation) -> String {
    if presentation.panelOwned {
      return "Your laptop screen is off."
    }
    if presentation.unavailability == .noConfirmedPanel {
      return reason(Unavailability.noConfirmedPanel)
    }
    if !presentation.wantsInternalOff {
      return "Your laptop screen stays on."
    }
    // External Only is chosen but not in effect. Say what it is waiting for, and say it as a
    // matter of timing, because the setting is being held and applies on its own.
    if let unavailability = presentation.unavailability, unavailability != .settling {
      if unavailability == .noNativeExternal {
        return "Waiting for a monitor. Your laptop screen turns off when you connect one."
      }
      return reason(unavailability)
    }
    return "Turning your laptop screen off."
  }

  /// A fault outranks work in progress, because it is the one a person can act on.
  static func alert(_ presentation: Presentation) -> MenuPanel.Alert? {
    let retry = presentation.operationInFlight ? nil : MenuAction.retryRecovery
    if let fault = presentation.fault {
      return .init(
        severity: .attention, title: status(presentation), detail: reason(fault), retry: retry
      )
    }
    guard presentation.waitingForRecovery || presentation.pendingRecovery else { return nil }
    return .init(
      severity: .working, title: status(presentation),
      detail: detail(presentation) ?? "", retry: retry
    )
  }

  /// The menu bar icon. Deliberately mirrors the order `status` reads its state in, so the
  /// icon and the words can never disagree about what the app is doing.
  static func glyph(_ presentation: Presentation) -> MenuGlyph {
    if presentation.fault != nil {
      return .attention
    }
    if presentation.waitingForRecovery {
      return .working
    }
    if presentation.panelOwned {
      return .externalOnly
    }
    if presentation.pendingRecovery || presentation.operationInFlight {
      return .working
    }
    return .allMonitors
  }

  static func status(_ presentation: Presentation) -> String {
    if presentation.waitingForRecovery {
      return "Waiting to turn your laptop screen back on"
    }
    if presentation.panelOwned {
      return "Your laptop screen is off"
    }
    if presentation.pendingRecovery {
      return "Finishing up"
    }
    if presentation.operationInFlight {
      return "Working…"
    }
    return presentation.canDisableNow
      ? "Ready to switch to External Only" : "External Only is not available right now"
  }

  /// The specific reason, never a bare unavailable state. A fault outranks anything else,
  /// because it is the thing the person can act on.
  static func detail(_ presentation: Presentation) -> String? {
    if presentation.waitingForRecovery {
      return
        "Recovery is retained until this Mac is awake, the lid is open, and this login session is available."
    }
    if let fault = presentation.fault {
      return reason(fault)
    }
    guard let unavailability = presentation.unavailability else { return nil }
    return reason(unavailability)
  }

  static func reason(_ unavailability: Unavailability) -> String {
    switch unavailability {
    case .noObservation: "Checking your displays."
    case .noConfirmedPanel: "This Mac has no built-in display to turn off."
    case .staleEvidence: "Reading your current display setup."
    case .lidClosed: "Open the lid. macOS controls your laptop screen while it is closed."
    case .notAwake: "Waiting for your Mac to wake up fully."
    case .sessionNotForeground: "Another user is logged in and in front."
    case .noNativeExternal: "Connect a monitor directly to this Mac."
    case .unsupportedTopology: "SoloDisplay has not been tested with this display arrangement."
    case .backendUnvalidated: "SoloDisplay has not checked this Mac yet."
    case .noRecoveryHelper: "SoloDisplay is not fully running. Quit it and open it again."
    case .settling: "Just a moment."
    case .unresolvedOwnership: "Finishing up from the last time SoloDisplay ran."
    case .faulted: "SoloDisplay stopped after a problem. Try again."
    case .shuttingDown: "SoloDisplay is quitting."
    }
  }

  static func reason(_ fault: Fault) -> String {
    switch fault {
    case .preferencesFailed:
      "Could not save your choice. It is active now but may not survive a restart. Fix storage access before restarting."
    case .configurationChanged:
      "Your displays changed while SoloDisplay was working, so it stopped rather than rewrite your setup."
    case .journalFailed:
      "Could not save a safety record, so nothing was changed."
    case .operationFailed:
      "That did not work, so SoloDisplay turned your laptop screen back on."
    case .operationTimedOut: "Your Mac did not respond in time."
    case .verificationFailed: "SoloDisplay could not confirm your screen actually changed."
    case .conflictingController:
      "Something else changed your laptop screen, so SoloDisplay stopped rather than fight it."
    case .identityChanged: "Your laptop screen is not the one SoloDisplay was tracking."
    case .recoveryExhausted:
      "SoloDisplay could not confirm your laptop screen came back on."
    case .priorRunUnresolved: "Finishing up from the last time SoloDisplay ran."
    case .protectionUnavailable:
      "SoloDisplay's safety net did not respond, so nothing was turned off."
    case .protectionLost:
      "SoloDisplay lost its safety net and turned your laptop screen back on."
    case .ownershipClearFailed:
      "Your laptop screen is back on, but SoloDisplay could not clear its record."
    case .operationRefused:
      "Things changed before the request went out, so nothing was touched."
    }
  }
}
