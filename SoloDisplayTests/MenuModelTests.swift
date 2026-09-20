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

  /// A panel that cannot be read is said so, rather than being reported as a screen that stays
  /// on. It is a passing state that SoloDisplay is already working its way out of, so unlike a
  /// Mac with no built-in screen it never takes the choice away.
  @Test func anUnreadableScreenIsSaidRatherThanReportedAsOn() {
    let shown = menuPanel(.init(working: true, unavailability: .panelUnreadable))
    #expect(shown.reality == MenuModel.reason(.panelUnreadable))
    #expect(shown.reality != "Your laptop screen stays on.")
    #expect(shown.externalOnly.isEnabled && shown.allMonitors.isEnabled)
  }

  @Test func onlyAMacWithNoBuiltInScreenOrAFailedStartCannotPickExternalOnly() {
    let mini = menuPanel(.init(unavailability: .noConfirmedPanel))
    #expect(!mini.externalOnly.isEnabled)
    #expect(mini.reality == "This Mac has no built-in display to turn off.")
    let broken = menuPanel(.init(unavailability: .notRunning))
    #expect(!broken.externalOnly.isEnabled && !broken.allMonitors.isEnabled)
    #expect(broken.glyph == .attention)
    for blocked in [Unavailability.lidClosed, .notAwake, .noNativeExternal, .settling,
                    .unsupportedTopology, .monitorShowsAnotherMachine] {
      #expect(menuPanel(.init(unavailability: blocked)).externalOnly.isEnabled)
    }
  }

  /// A monitor switched to another machine is a matter of when, like an unplugged one: the
  /// arrangement stays chosen and stays pickable, and nothing about it is a fault.
  @Test func aMonitorShowingAnotherMachineIsAMatterOfWhen() {
    let shown = menuPanel(.init(
      wantsInternalOff: true, unavailability: .monitorShowsAnotherMachine
    ))
    #expect(shown.reality == "Set your monitor's input back to this Mac.")
    #expect(shown.externalOnly.isSelected)
    #expect(shown.externalOnly.isEnabled)
    #expect(shown.glyph == .allMonitors)
    #expect(shown.alert == nil)
  }

  /// A monitor going dark is the least expected thing a person can be shown, so the menu says it
  /// before anything else, and says it in either arrangement.
  @Test func aMonitorTurnedOffForShowingAnotherComputerIsSaidPlainly() {
    var one = Presentation(wantsInternalOff: false)
    one.suppressedMonitors = 1
    #expect(menuPanel(one).reality == "A monitor showing another computer is turned off.")

    var several = Presentation(wantsInternalOff: true, panelOff: true)
    several.suppressedMonitors = 2
    #expect(
      menuPanel(several).reality
        == "2 monitors showing another computer are turned off."
    )
    // It is not a fault, so nothing is raised about it.
    #expect(menuPanel(one).alert == nil)
    #expect(menuPanel(one).allMonitors.isEnabled)
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

  @Test func brightnessKeysShowWhenPermissionIsMissing() {
    let off = MenuModel.panel(.init(), launchAtLogin: false)
    #expect(!off.brightnessKeys.isOn && !off.brightnessKeys.isBlocked)
    let blocked = MenuModel.panel(
      .init(), launchAtLogin: false, brightnessKeys: true, brightnessNeedsPermission: true
    )
    #expect(blocked.brightnessKeys.isOn && blocked.brightnessKeys.isBlocked)
    // Permission only matters once the person has asked for the keys.
    let notAsked = MenuModel.panel(
      .init(), launchAtLogin: false, brightnessKeys: false, brightnessNeedsPermission: true
    )
    #expect(!notAsked.brightnessKeys.isBlocked)
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
      let transition = Controller.reduce(state, event, at: time)
      state = transition.state
      // The executor always answers when the monitors are asked, even with nothing, and nothing
      // is what a monitor that cannot be asked over DDC gives.
      if transition.effects.contains(.readInputSources) {
        send(.inputSourcesRead(.unknown, sampledAt: time), at: time)
      }
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
