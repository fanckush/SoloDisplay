import LidlessCore
import Testing
@testable import Lidless

private func presentation(
  mode: Mode = .manual, manualRequestActive: Bool = false, panelOwned: Bool = false,
  operationInFlight: Bool = false, pendingRecovery: Bool = false, fault: Fault? = nil,
  unavailability: Unavailability? = nil
) -> Presentation {
  .init(
    mode: mode, manualRequestActive: manualRequestActive, panelOwned: panelOwned,
    operationInFlight: operationInFlight, pendingRecovery: pendingRecovery, fault: fault,
    unavailability: unavailability
  )
}

private func menu(
  _ value: Presentation, launchAtLogin: Bool = false, automaticAvailable: Bool = true
) -> [MenuItem] {
  MenuModel.items(value, launchAtLogin: launchAtLogin, automaticAvailable: automaticAvailable)
}

private func item(_ items: [MenuItem], _ action: MenuAction) -> MenuItem? {
  items.first { $0.action == action }
}

struct MenuModelTests {
  @Test func anUnavailableConfigurationNamesItsReasonAndOffersNoDisable() {
    let items = menu(presentation(unavailability: .noNativeExternal))
    #expect(items.first?.title == "Turning the internal display off is unavailable")
    #expect(items.contains { $0.title == MenuModel.reason(Unavailability.noNativeExternal) })
    #expect(item(items, .turnInternalOff)?.enabled == false)
    // Nothing to recover, so no retry is offered.
    #expect(item(items, .retryRecovery) == nil)
  }

  @Test func everyBlockedStateExplainsItselfInPlainWords() {
    for reason in [
      Unavailability.noObservation, .noConfirmedPanel, .staleEvidence, .lidClosed, .notAwake,
      .sessionNotForeground, .noNativeExternal, .unsupportedTopology, .backendUnvalidated,
      .noRecoveryHelper, .settling, .unresolvedOwnership, .faulted, .shuttingDown
    ] {
      let text = MenuModel.reason(reason)
      #expect(!text.isEmpty)
      #expect(text.hasSuffix("."))
      #expect(!text.contains("nil") && !text.contains("Optional"))
    }
    for fault in [
      Fault.journalFailed, .operationFailed, .operationTimedOut, .verificationFailed,
      .conflictingController, .identityChanged, .recoveryExhausted, .priorRunUnresolved,
      .protectionUnavailable, .protectionLost, .ownershipClearFailed, .operationRefused
    ] {
      let text = MenuModel.reason(fault)
      #expect(!text.isEmpty)
      #expect(text.hasSuffix("."))
    }
  }

  @Test func aFaultIsShownAheadOfTheGenericUnavailableReason() {
    let items = menu(presentation(fault: .protectionLost, unavailability: .faulted))
    #expect(items.contains { $0.title == MenuModel.reason(Fault.protectionLost) })
    #expect(!items.contains { $0.title == MenuModel.reason(Unavailability.faulted) })
    #expect(item(items, .retryRecovery)?.enabled == true)
  }

  @Test func anOwnedPanelOffersTurningItBackOn() {
    let items = menu(presentation(panelOwned: true))
    #expect(items.first?.title == "Internal display is off")
    #expect(item(items, .turnInternalOn)?.enabled == true)
    #expect(item(items, .turnInternalOff) == nil)
  }

  @Test func aPendingActionDoesNotOfferACompetingOne() {
    let items = menu(presentation(panelOwned: true, operationInFlight: true))
    #expect(item(items, .turnInternalOn)?.enabled == false)
    #expect(items.first?.title == "Internal display is off")
  }

  @Test func unresolvedRecoveryIsShownAsRecoveryNotSuccess() {
    let items = menu(presentation(pendingRecovery: true, unavailability: .unresolvedOwnership))
    #expect(items.first?.title == "Finishing recovery")
    #expect(item(items, .retryRecovery) != nil)
    // Nothing here claims the display was restored.
    #expect(!items.contains { $0.title.lowercased().contains("restored") })
  }

  @Test func automaticStaysLockedUntilTheManualPathHasWorkedHere() {
    let locked = menu(presentation(), automaticAvailable: false)
    #expect(item(locked, .selectAutomatic)?.enabled == false)
    #expect(item(locked, .selectAutomatic)?.title == "Automatic (after a manual test)")

    let unlocked = menu(presentation(), automaticAvailable: true)
    #expect(item(unlocked, .selectAutomatic)?.enabled == true)
    #expect(item(unlocked, .selectAutomatic)?.title == "Automatic")
  }

  @Test func eachModeOffersItsOwnControls() {
    let automatic = menu(presentation(mode: .automatic))
    #expect(item(automatic, .keepInternalOn) != nil)
    #expect(item(automatic, .turnInternalOff) == nil)
    #expect(item(automatic, .selectAutomatic)?.checked == true)

    let paused = menu(presentation(mode: .automaticPaused))
    #expect(item(paused, .resumeAutomatic) != nil)
    #expect(item(paused, .keepInternalOn) == nil)
    // A paused choice still reads as automatic, not as manual.
    #expect(item(paused, .selectManual)?.checked == false)
  }

  @Test func launchAtLoginReflectsTheStoredChoice() {
    #expect(item(menu(presentation()), .toggleLaunchAtLogin)?.checked == false)
    #expect(item(menu(presentation(), launchAtLogin: true), .toggleLaunchAtLogin)?.checked == true)
  }

  @Test func noProductionMenuActionCanReachALabCommand() {
    let actions: Set<MenuAction> = [
      .selectManual, .selectAutomatic, .turnInternalOff, .turnInternalOn, .keepInternalOn,
      .resumeAutomatic, .retryRecovery, .toggleLaunchAtLogin, .exportDiagnostics, .quit
    ]
    // The full menu surface is exactly the agreed set; nothing else is reachable.
    var offered: Set<MenuAction> = []
    for value in [
      presentation(), presentation(panelOwned: true), presentation(mode: .automatic),
      presentation(mode: .automaticPaused), presentation(fault: .operationFailed)
    ] {
      offered.formUnion(menu(value).compactMap(\.action))
    }
    #expect(offered.isSubset(of: actions))
    for action in actions {
      #expect(!action.rawValue.hasPrefix("--"))
      #expect(!action.rawValue.lowercased().contains("lab"))
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
    #expect(item(menu(Controller.presentation(state, at: 0)), .turnInternalOff)?.enabled == false)

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
    let offItems = menu(Controller.presentation(state, at: 2120))
    #expect(offItems.first?.title == "Internal display is off")
    #expect(item(offItems, .turnInternalOn) != nil)
  }
}
