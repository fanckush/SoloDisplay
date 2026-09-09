import LidlessCore
import LidlessPlatform

/// Everything a menu item can ask for. A production action never reaches a lab command.
nonisolated enum MenuAction: String, Equatable, Sendable {
  case selectManual, selectAutomatic
  case turnInternalOff, turnInternalOn
  case keepInternalOn, resumeAutomatic
  case retryRecovery
  case toggleLaunchAtLogin
  case exportDiagnostics
  case quit
}

nonisolated struct MenuItem: Equatable, Sendable {
  var title: String
  var action: MenuAction?
  var enabled = true
  var checked = false
  var separator = false

  static let separator = MenuItem(title: "", action: nil, separator: true)
}

/// Turns controller state into the menu, and nothing else. Keeping this pure means the wording
/// of every refusal can be tested without launching an app or touching a display.
nonisolated enum MenuModel {
  static func items(
    _ presentation: Presentation, launchAtLogin: Bool, automaticAvailable: Bool
  ) -> [MenuItem] {
    var items: [MenuItem] = [
      .init(title: status(presentation), action: nil, enabled: false)
    ]
    if let detail = detail(presentation) {
      items.append(.init(title: detail, action: nil, enabled: false))
    }
    items.append(.separator)

    items.append(
      .init(
        title: "Manual", action: .selectManual, enabled: presentation.mode != .manual,
        checked: presentation.mode == .manual))
    items.append(
      .init(
        title: automaticAvailable ? "Automatic" : "Automatic (after a manual test)",
        action: .selectAutomatic, enabled: automaticAvailable && presentation.mode == .manual,
        checked: presentation.mode != .manual))
    items.append(.separator)

    switch presentation.mode {
    case .manual:
      if presentation.panelOwned || presentation.manualRequestActive {
        items.append(
          .init(
            title: "Turn Internal Display On", action: .turnInternalOn,
            enabled: !presentation.operationInFlight))
      } else {
        items.append(
          .init(
            title: "Turn Internal Display Off", action: .turnInternalOff,
            enabled: presentation.canDisableNow))
      }
    case .automatic:
      items.append(.init(title: "Keep Internal Display On", action: .keepInternalOn))
    case .automaticPaused:
      items.append(.init(title: "Resume Automatic", action: .resumeAutomatic))
    }

    if presentation.fault != nil || presentation.pendingRecovery {
      items.append(
        .init(
          title: "Retry Recovery", action: .retryRecovery,
          enabled: !presentation.operationInFlight))
    }
    items.append(.separator)
    items.append(
      .init(title: "Launch at Login", action: .toggleLaunchAtLogin, checked: launchAtLogin))
    items.append(.init(title: "Export Diagnostics…", action: .exportDiagnostics))
    items.append(.separator)
    items.append(.init(title: "Quit Lidless", action: .quit))
    return items
  }

  static func status(_ presentation: Presentation) -> String {
    if presentation.panelOwned { return "Internal display is off" }
    if presentation.pendingRecovery { return "Finishing recovery" }
    if presentation.operationInFlight { return "Working…" }
    return presentation.canDisableNow
      ? "Ready to turn the internal display off" : "Turning the internal display off is unavailable"
  }

  /// The specific reason, never a bare unavailable state. A fault outranks anything else,
  /// because it is the thing the person can act on.
  static func detail(_ presentation: Presentation) -> String? {
    if let fault = presentation.fault { return reason(fault) }
    guard let unavailability = presentation.unavailability else { return nil }
    return reason(unavailability)
  }

  static func reason(_ unavailability: Unavailability) -> String {
    switch unavailability {
    case .noObservation: "Lidless has not observed the displays yet."
    case .noConfirmedPanel: "Lidless cannot positively identify this Mac's internal display."
    case .staleEvidence: "Waiting for current display information."
    case .lidClosed: "The lid is closed, so macOS is in charge of the internal display."
    case .notAwake: "Waiting until this Mac is fully awake."
    case .sessionNotForeground: "Another login session is in front."
    case .noNativeExternal: "No directly connected external display was recognized."
    case .unsupportedTopology: "This display arrangement is not one Lidless has tested."
    case .backendUnvalidated:
      "Display control has not been validated on this Mac and this macOS version yet."
    case .noRecoveryHelper: "The recovery helper is not available, so nothing will be turned off."
    case .settling: "Waiting for the display arrangement to stay steady."
    case .unresolvedOwnership: "Lidless is still resolving an earlier run's record."
    case .faulted: "Lidless stopped after a problem. Use Retry Recovery."
    case .shuttingDown: "Lidless is quitting."
    }
  }

  static func reason(_ fault: Fault) -> String {
    switch fault {
    case .preferencesFailed:
      "Could not save your preference. Keep Internal On is effective now but may not survive restart. Resolve storage access before restarting."
    case .configurationChanged:
      "The display arrangement did not match the recorded configuration. Recovery remains unverified; Lidless will not rewrite your external settings."
    case .journalFailed:
      "Lidless could not record ownership durably, so it did not turn anything off."
    case .operationFailed:
      "A display request failed. Lidless put the internal display back."
    case .operationTimedOut: "A display request did not respond in time."
    case .verificationFailed: "Lidless could not confirm the display actually changed."
    case .conflictingController:
      "Something else changed the internal display, so Lidless stopped rather than fighting it."
    case .identityChanged: "The internal display is not the one Lidless was tracking."
    case .recoveryExhausted:
      "Lidless could not confirm the internal display came back on. Its record is kept."
    case .priorRunUnresolved: "Lidless is resolving ownership left by an earlier run."
    case .protectionUnavailable:
      "The recovery helper did not confirm protection, so nothing was turned off."
    case .protectionLost:
      "Lidless lost contact with its recovery helper and put the internal display back."
    case .ownershipClearFailed:
      "The internal display is back on, but Lidless could not clear its record."
    case .operationRefused:
      "Conditions changed before the request was sent, so no display was changed."
    }
  }
}
