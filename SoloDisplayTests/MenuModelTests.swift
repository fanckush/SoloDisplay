import SoloDisplayCore
import SoloDisplayPlatform
import Testing
@testable import SoloDisplay

private func menuPanel(_ value: Presentation, launchAtLogin: Bool = false) -> MenuPanel {
  MenuModel.panel(value, launchAtLogin: launchAtLogin)
}

struct MenuModelTests {
  @Test func everyReasonIsPlainAndFinished() {
    for reason in Unavailability.allCases {
      let text = MenuModel.reason(reason)
      #expect(!text.isEmpty && text.hasSuffix("."))
    }
    for trouble in Trouble.allCases {
      #expect(!MenuModel.title(trouble).isEmpty && !MenuModel.title(trouble).hasSuffix("."))
      #expect(MenuModel.reason(trouble).hasSuffix("."))
    }
  }

  @Test func anOffScreenKeepsTheWayBack() {
    let shown = menuPanel(.init(wantsInternalOff: true, panelOff: true))
    #expect(shown.externalOnly.isSelected && shown.externalOnly.isActive)
    #expect(shown.allMonitors.isEnabled)
    #expect(shown.statusDescription == "Your laptop screen is off")
    #expect(shown.reality == "Your laptop screen is off.")
    #expect(shown.glyph == .externalOnly)
    #expect(shown.alert == nil)
  }

  @Test func workInProgressShowsOnTheTileAndIconRatherThanAsAnAlert() {
    let shown = menuPanel(.init(wantsInternalOff: true, working: true))
    #expect(shown.externalOnly.isPending)
    #expect(shown.glyph == .working)
    #expect(shown.alert == nil)
    // Nothing locks the choices: changing your mind mid-change is always allowed.
    #expect(shown.allMonitors.isEnabled && shown.externalOnly.isEnabled)
  }

  @Test func onlyAProblemThatLastsBecomesAnAlertAndItOffersTryAgain() {
    for trouble in Trouble.allCases {
      let shown = menuPanel(.init(wantsInternalOff: true, trouble: trouble))
      #expect(shown.alert?.severity == .attention)
      #expect(shown.alert?.retry == .retryRecovery)
      #expect(shown.alert?.detail == MenuModel.reason(trouble))
      #expect(shown.glyph == .attention)
    }
  }

  @Test func settlingAlreadyShowsWorkWhenExternalOnlyIsChosen() {
    #expect(MenuModel.glyph(.init(wantsInternalOff: true, unavailability: .settling)) == .working)
    #expect(MenuModel.glyph(.init(unavailability: .settling)) == .allMonitors)
  }

  @Test func theChosenArrangementSurvivesAnUnpluggedMonitor() {
    let shown = menuPanel(.init(wantsInternalOff: true, unavailability: .noNativeExternal))
    #expect(shown.externalOnly.isSelected)
    #expect(!shown.externalOnly.isActive)
    #expect(shown.externalOnly.isEnabled)
    #expect(shown.reality == "Waiting for a monitor.")
    #expect(shown.glyph == .allMonitors)
  }

  @Test func onlyAMacWithNoBuiltInScreenOrAFailedStartCannotPickExternalOnly() {
    let mini = menuPanel(.init(unavailability: .noConfirmedPanel))
    #expect(!mini.externalOnly.isEnabled)
    #expect(mini.reality == "This Mac has no built-in display to turn off.")
    let broken = menuPanel(.init(unavailability: .notRunning))
    #expect(!broken.externalOnly.isEnabled && !broken.allMonitors.isEnabled)
    #expect(broken.glyph == .attention)
    for blocked in [Unavailability.lidClosed, .notAwake, .noNativeExternal, .settling,
                    .unsupportedTopology] {
      #expect(menuPanel(.init(unavailability: blocked)).externalOnly.isEnabled)
    }
  }

  @Test func exactlyOneArrangementIsEverChosen() {
    for wants in [false, true] {
      let shown = menuPanel(.init(wantsInternalOff: wants))
      #expect(shown.allMonitors.isSelected != shown.externalOnly.isSelected)
      #expect(shown.externalOnly.isSelected == wants)
    }
  }

  @Test func launchAtLoginReflectsTheStoredChoice() {
    #expect(menuPanel(.init()).launchAtLogin.isOn == false)
    #expect(menuPanel(.init(), launchAtLogin: true).launchAtLogin.isOn == true)
  }

  @Test func everyMenuActionSurvivesTheDiagnosticsBridge() {
    // The action field of an exported record is filled by converting raw values, which drops a
    // mismatch silently, so every action needs a counterpart.
    for action in MenuAction.allCases {
      #expect(
        OperationalEvent.Action(rawValue: action.rawValue) != nil,
        "MenuAction.\(action.rawValue) has no OperationalEvent.Action counterpart."
      )
    }
  }

  @Test func everyStringThePanelCanShowIsPlain() {
    let presentations = [Presentation(), .init(wantsInternalOff: true, panelOff: true)]
      + Unavailability.allCases.map { Presentation(wantsInternalOff: true, unavailability: $0) }
      + Trouble.allCases.map { Presentation(wantsInternalOff: true, trouble: $0) }
    for value in presentations {
      for text in menuPanel(value).allStrings {
        #expect(!text.isEmpty)
        #expect(!text.contains("nil") && !text.contains("Optional"))
        for jargon in [
          "ownership",
          "guardian",
          "worker",
          "topology",
          "backend",
          "internal display"
        ] {
          #expect(!text.lowercased().contains(jargon), "\(jargon) leaked into: \(text)")
        }
      }
    }
  }

  @Test func theMenuFollowsTheRealControllerThroughAWholeCycle() {
    var state = ControllerState(mode: .automaticPaused)
    let panel = PanelTarget(displayID: 1, displayUUID: "p", bootID: "b", loginID: 1)
    let ready = Environment(
      panel: panel, panelState: .enabled, power: .awake, lid: .open, foregroundSession: .yes,
      nativeExternalAvailable: .yes, supportedTopology: .yes
    )
    var sequence: UInt64 = 0
    func send(_ event: Event, at time: Instant) {
      state = Controller.reduce(state, event, at: time).state
    }
    func observe(_ environment: Environment, at time: Instant) {
      sequence += 1
      send(
        .observed(.init(sequence: sequence, sampledAt: time, environment: environment)),
        at: time
      )
    }

    observe(ready, at: 0)
    let atRest = menuPanel(Controller.presentation(state, at: 0))
    #expect(atRest.externalOnly.isEnabled && !atRest.externalOnly.isSelected)
    #expect(atRest.allMonitors.isActive)

    send(.selectMode(.automatic), at: 1)
    observe(ready, at: 600)
    observe(ready, at: 2100)
    #expect(Controller.presentation(state, at: 2100).working)
    send(.recordWritten(panel, succeeded: true), at: 2101)
    send(.guardianReady, at: 2102)
    send(.workerFinished(.done), at: 2110)
    var off = ready
    off.panelState = .disabled
    observe(off, at: 2120)

    let shown = menuPanel(Controller.presentation(state, at: 2120))
    #expect(shown.statusDescription == "Your laptop screen is off")
    #expect(shown.glyph == .externalOnly)
    #expect(shown.allMonitors.isEnabled)
    #expect(shown.alert == nil)
  }
}
