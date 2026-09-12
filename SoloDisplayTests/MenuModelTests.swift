import SoloDisplayCore
import SoloDisplayPlatform
import Testing
@testable import SoloDisplay

private func presentation(
  mode: Mode = .manual, manualRequestActive: Bool = false, panelOwned: Bool = false,
  operationInFlight: Bool = false, pendingRecovery: Bool = false, fault: Fault? = nil,
  unavailability: Unavailability? = nil, wantsInternalOff: Bool = false,
  waitingForRecovery: Bool = false
) -> Presentation {
  var value = Presentation(
    mode: mode, manualRequestActive: manualRequestActive, panelOwned: panelOwned,
    operationInFlight: operationInFlight, pendingRecovery: pendingRecovery, fault: fault,
    unavailability: unavailability
  )
  // The reducer sets this from wantsOff. Hand-built presentations have to say it themselves.
  value.wantsInternalOff = wantsInternalOff
  value.waitingForRecovery = waitingForRecovery
  return value
}

private func menuPanel(_ value: Presentation, launchAtLogin: Bool = false) -> MenuPanel {
  MenuModel.panel(value, launchAtLogin: launchAtLogin)
}

struct MenuModelTests {
  @Test func everyBlockedStateExplainsItselfInPlainWords() {
    // Driven from the enums, not a hand-kept list. The old lists had already fallen behind by
    // two faults, which is how a string naming deleted UI survived in the table unnoticed.
    for reason in Unavailability.allCases {
      let text = MenuModel.reason(reason)
      #expect(!text.isEmpty)
      #expect(text.hasSuffix("."))
      #expect(!text.contains("nil") && !text.contains("Optional"))
    }
    for fault in Fault.allCases {
      let text = MenuModel.reason(fault)
      #expect(!text.isEmpty)
      #expect(text.hasSuffix("."))
      #expect(!text.contains("nil") && !text.contains("Optional"))
    }
  }

  @Test func anOffPanelKeepsTheWayBack() {
    let shown = menuPanel(presentation(panelOwned: true, wantsInternalOff: true))
    #expect(shown.externalOnly.isSelected)
    #expect(shown.allMonitors.isEnabled)
    #expect(shown.allMonitors.action == .selectAllMonitors)
    #expect(shown.statusDescription == "Your laptop screen is off")
    #expect(shown.reality == "Your laptop screen is off.")
  }

  @Test func aPendingActionDoesNotOfferACompetingOne() {
    let shown = menuPanel(presentation(
      panelOwned: true, operationInFlight: true, wantsInternalOff: true
    ))
    #expect(!shown.allMonitors.isEnabled)
    #expect(!shown.externalOnly.isEnabled)
    #expect(shown.externalOnly.isPending)
    #expect(shown.statusDescription == "Your laptop screen is off")
  }

  @Test func unresolvedRecoveryIsShownAsRecoveryNotSuccess() {
    let shown = menuPanel(presentation(
      pendingRecovery: true, unavailability: .unresolvedOwnership
    ))
    #expect(shown.statusDescription == "Finishing up")
    #expect(shown.alert?.severity == .working)
    #expect(shown.alert?.retry == .retryRecovery)
    // Nothing here claims the display was restored.
    #expect(!shown.allStrings.contains { $0.lowercased().contains("restored") })
  }

  @Test func everyModeLandsOnExactlyOneTile() {
    // Manual is unreachable from the panel now, but a decoded preference can still carry it,
    // and at rest it means the same thing the paused arrangement does.
    for mode in [Mode.manual, .automaticPaused] {
      #expect(menuPanel(presentation(mode: mode)).allMonitors.isSelected)
    }
    let automatic = menuPanel(presentation(mode: .automatic, wantsInternalOff: true))
    #expect(automatic.externalOnly.isSelected)
    #expect(automatic.externalOnly.action == .selectExternalOnly)
  }

  @Test func theMenuBarIconReportsWhichArrangementIsLive() {
    #expect(MenuModel.glyph(presentation()) == .allMonitors)
    #expect(MenuModel.glyph(presentation(panelOwned: true)) == .externalOnly)
    #expect(MenuModel.glyph(presentation(fault: .protectionLost)) == .attention)
    #expect(MenuModel.glyph(presentation(operationInFlight: true)) == .working)
    // A panel that is off reads as off, not as busy, even though owning it also counts as
    // recovery being outstanding. This is the same precedence the status line uses.
    #expect(MenuModel.glyph(presentation(panelOwned: true, pendingRecovery: true)) == .externalOnly)
    #expect(MenuGlyph.allCases.allSatisfy { !$0.symbolName.isEmpty })
  }

  @Test func launchAtLoginReflectsTheStoredChoice() {
    #expect(menuPanel(presentation()).launchAtLogin.isOn == false)
    #expect(menuPanel(presentation(), launchAtLogin: true).launchAtLogin.isOn == true)
  }

  @Test func noProductionMenuActionCanReachALabCommand() {
    let actions = Set(MenuAction.allCases)
    // The full panel surface is exactly the agreed set; nothing else is reachable.
    var offered: Set<MenuAction> = []
    for value in [
      presentation(), presentation(panelOwned: true, wantsInternalOff: true),
      presentation(mode: .automatic, wantsInternalOff: true),
      presentation(mode: .automaticPaused), presentation(fault: .operationFailed)
    ] {
      let shown = menuPanel(value)
      offered.formUnion([shown.allMonitors.action, shown.externalOnly.action])
      offered.formUnion([shown.launchAtLogin.action])
      offered.formUnion(shown.commands.map(\.action))
      offered.formUnion([shown.alert?.retry].compactMap(\.self))
    }
    #expect(offered.isSubset(of: actions))
    for action in actions {
      #expect(!action.rawValue.hasPrefix("--"))
      #expect(!action.rawValue.lowercased().contains("lab"))
    }
  }

  @Test func everyMenuActionSurvivesTheDiagnosticsBridge() {
    // ControllerRuntime records an action by converting MenuAction's raw value into the
    // separately declared OperationalEvent.Action. That conversion is failable and its result is
    // assigned straight into an optional field, so a name that drifts apart here costs a
    // silently empty action in every exported record, with nothing else reporting the loss.
    for action in MenuAction.allCases {
      #expect(
        OperationalEvent.Action(rawValue: action.rawValue) != nil,
        "MenuAction.\(action.rawValue) has no OperationalEvent.Action counterpart."
      )
    }
  }

  @Test func exactlyOneArrangementIsEverChosen() {
    for value in [
      presentation(), presentation(panelOwned: true, wantsInternalOff: true),
      presentation(unavailability: .noNativeExternal, wantsInternalOff: true),
      presentation(fault: .operationFailed, unavailability: .faulted),
      presentation(operationInFlight: true, wantsInternalOff: true)
    ] {
      let shown = menuPanel(value)
      #expect(shown.allMonitors.isSelected != shown.externalOnly.isSelected)
      #expect(shown.allMonitors.isSelected == !value.wantsInternalOff)
    }
  }

  @Test func theChosenArrangementSurvivesAnUnpluggedMonitor() {
    // External Only is a stored intent, not a reading of the hardware. Losing the monitor turns
    // the laptop screen back on without unpicking the choice.
    let shown = menuPanel(presentation(unavailability: .noNativeExternal, wantsInternalOff: true))
    #expect(shown.externalOnly.isSelected)
    // Chosen, but not in effect. The tile has to be able to say both at once, and it must stay
    // pickable: an unplugged monitor is a question of when, not of whether.
    #expect(!shown.externalOnly.isActive)
    #expect(shown.externalOnly.isEnabled)
    #expect(shown.reality == "Waiting for a monitor.")
    #expect(shown.glyph == .allMonitors)
  }

  @Test func nothingIsWaitingWhenTheChoiceIsAlreadyInEffect() {
    let off = menuPanel(presentation(panelOwned: true, wantsInternalOff: true))
    #expect(off.externalOnly.isSelected && off.externalOnly.isActive)
    let on = menuPanel(presentation())
    #expect(on.allMonitors.isSelected && on.allMonitors.isActive)
  }

  @Test func onlyAMacWithNoBuiltInScreenCannotPickExternalOnly() {
    // The one refusal that is about the machine rather than about the moment. A Mac with no
    // built-in display has nothing to turn off, and no amount of waiting changes that.
    let mini = menuPanel(presentation(unavailability: .noConfirmedPanel))
    #expect(!mini.externalOnly.isEnabled)
    #expect(mini.reality == "This Mac has no built-in display to turn off.")

    // Everything else leaves the choice standing, including states that block it right now.
    for blocked in [Unavailability.lidClosed, .notAwake, .noNativeExternal, .settling,
                    .noRecoveryHelper, .staleEvidence] {
      #expect(menuPanel(presentation(unavailability: blocked)).externalOnly.isEnabled)
    }
    // A gate never explains itself inside a label.
    #expect(!mini.externalOnly.title.contains("("))
    #expect(!mini.allMonitors.title.contains("("))
  }

  @Test func aFaultBecomesAnAlertThatOutranksTheRealityLine() {
    let shown = menuPanel(presentation(fault: .protectionLost, unavailability: .faulted))
    #expect(shown.alert?.severity == .attention)
    #expect(shown.alert?.detail == MenuModel.reason(Fault.protectionLost))
    #expect(shown.alert?.retry == .retryRecovery)
    #expect(shown.glyph == .attention)
    // Work in progress is a different severity, and it is not offered a retry mid-flight.
    let working = menuPanel(presentation(
      panelOwned: true, operationInFlight: true, pendingRecovery: true, wantsInternalOff: true,
      waitingForRecovery: true
    ))
    #expect(working.alert?.severity == .working)
    #expect(working.alert?.retry == nil)
  }

  @Test func aScreenThatIsSimplyOffIsNotAnAlert() {
    // Ownership is retained for the whole time the panel is legitimately off, so pendingRecovery
    // is true throughout the resting state. Treating that as recovery put a spinner, a blank
    // line and a Try Again on the one state where nothing whatsoever is wrong.
    let resting = menuPanel(presentation(
      panelOwned: true, pendingRecovery: true, wantsInternalOff: true
    ))
    #expect(resting.alert == nil)
    #expect(resting.reality == "Your laptop screen is off.")

    // A genuine wait still raises one, and it always has something to say.
    let waiting = menuPanel(presentation(
      panelOwned: true, pendingRecovery: true, wantsInternalOff: true, waitingForRecovery: true
    ))
    #expect(waiting.alert?.severity == .working)
    #expect(waiting.alert?.retry == .retryRecovery)
    #expect(!(waiting.alert?.detail.isEmpty ?? true))
  }

  @Test func noAlertEverShowsAnEmptyExplanation() {
    for value in [
      presentation(panelOwned: true, pendingRecovery: true, wantsInternalOff: true,
                   waitingForRecovery: true),
      presentation(pendingRecovery: true, unavailability: .unresolvedOwnership),
      presentation(fault: .ownershipClearFailed, unavailability: .faulted),
      presentation(fault: .preferencesFailed)
    ] {
      guard let alert = menuPanel(value).alert else { continue }
      #expect(!alert.title.isEmpty)
      #expect(!alert.detail.isEmpty)
    }
  }

  @Test func everyStringThePanelCanShowIsPlainAndFinished() {
    for value in [
      presentation(), presentation(panelOwned: true, wantsInternalOff: true),
      presentation(pendingRecovery: true, unavailability: .unresolvedOwnership),
      presentation(fault: .recoveryExhausted, unavailability: .faulted),
      presentation(unavailability: .noNativeExternal, wantsInternalOff: true)
    ] {
      for text in menuPanel(value).allStrings {
        #expect(!text.isEmpty)
        #expect(!text.contains("nil") && !text.contains("Optional"))
        // Words from the implementation, not from anybody's desk.
        for jargon in ["ownership", "durabl", "topology", "backend", "internal display"] {
          #expect(!text.lowercased().contains(jargon), "\(jargon) leaked into: \(text)")
        }
      }
    }
  }

  @Test func theMenuFollowsARealControllerThroughAWholeCycle() throws {
    // Driven by the actual reducer, not hand-written presentations.
    var state = ControllerState(mode: .manual)
    state.protectionAvailable = true
    let panel = PanelTarget(displayID: 1, displayUUID: "p", bootID: "b", loginID: 1)
    let ready = Environment(
      panel: panel, panelState: .enabled, power: .awake, lid: .open, foregroundSession: .yes,
      nativeExternalAvailable: .yes, supportedTopology: .yes, backendValidated: .yes
    )

    func send(_ event: Event, at time: Instant) {
      state = Controller.reduce(state, event, at: time).state
    }
    var sequence: UInt64 = 0
    func observe(_ environment: Environment, at time: Instant) {
      sequence += 1
      send(
        .observed(.init(sequence: sequence, sampledAt: time, environment: environment)), at: time
      )
    }

    observe(ready, at: 0)
    // Pickable from the start. Settling is a wait, not a refusal.
    let atRest = menuPanel(Controller.presentation(state, at: 0))
    #expect(atRest.externalOnly.isEnabled)
    #expect(!atRest.externalOnly.isSelected)
    #expect(atRest.allMonitors.isActive)

    send(.manualOff, at: 1)
    observe(ready, at: 600)
    observe(ready, at: 2100)
    let armed = Controller.presentation(state, at: 2100)
    #expect(armed.operationInFlight)

    try send(.journalSaved(operationID: #require(state.operation?.id), succeeded: true), at: 2101)
    try send(
      .protectionArmed(operationID: #require(state.operation?.id), succeeded: true),
      at: 2102
    )
    try send(
      .operationReturned(operationID: #require(state.operation?.id), succeeded: true),
      at: 2110
    )
    var suppressed = ready
    suppressed.panelState = .disabled
    observe(suppressed, at: 2120)
    let off = menuPanel(Controller.presentation(state, at: 2120))
    #expect(off.statusDescription == "Your laptop screen is off")
    #expect(off.allMonitors.isEnabled)

    // The tile follows the reducer's own intent rather than a separately maintained rule.
    for time in [Instant(0), 1, 600, 2100, 2110, 2120] {
      let shown = menuPanel(Controller.presentation(state, at: time))
      #expect(shown.externalOnly.isSelected == state.wantsOff)
    }
    #expect(menuPanel(Controller.presentation(state, at: 2120)).glyph == .externalOnly)
  }
}
