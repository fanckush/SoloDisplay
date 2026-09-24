import Testing
@testable import SoloDisplayCore

let panel = PanelTarget(displayID: 1, displayUUID: "panel-1", bootID: "boot-1", loginID: 42)

func environment(
  panelState: PanelState = .enabled, external: Fact = .yes,
  power: Power = .awake, lid: Lid = .open
) -> Environment {
  .init(
    panel: panel, panelState: panelState, power: power, lid: lid,
    foregroundSession: .yes, nativeExternalAvailable: external, supportedTopology: .yes
  )
}

struct Rig {
  var state: ControllerState
  var sequence: UInt64 = 0
  /// What the monitors say when asked. The executor always answers, even with nothing, so the rig
  /// answers too: `.unknown` is what every monitor that cannot do DDC gives, and it is the answer
  /// under which the controller must behave exactly as it did before it ever asked.
  var monitorAnswer: Fact = .unknown
  var answersMonitors = true

  init(mode: Mode = .automatic, record: PanelTarget? = nil, inputDetectionEnabled: Bool = true) {
    state = .init(mode: mode, record: record, inputDetectionEnabled: inputDetectionEnabled)
  }

  @discardableResult mutating func send(_ event: Event, at time: Instant) -> [Effect] {
    let transition = Controller.reduce(state, event, at: time)
    state = transition.state
    var effects = transition.effects
    if answersMonitors, effects.contains(.readInputSources) {
      effects += send(.inputSourcesRead(monitorAnswer, sampledAt: time), at: time)
    }
    return effects
  }

  @discardableResult mutating func observe(_ value: Environment = environment(), at time: Instant)
    -> [Effect] {
    sequence += 1
    return send(.observed(.init(sequence: sequence, sampledAt: time, environment: value)), at: time)
  }

  /// Settles on the full interval, then lands the record and the guardian. Returns the effects of
  /// the guardian becoming ready, which is when the disable worker is requested.
  @discardableResult mutating func reachDisable() -> [Effect] {
    observe(at: 0)
    observe(at: 2000)
    send(.recordWritten(panel, succeeded: true), at: 2001)
    return send(.guardianReady, at: 2002)
  }

  /// The laptop screen is off and guarded.
  mutating func off() {
    reachDisable()
    send(.workerFinished(.done), at: 2010)
    observe(environment(panelState: .disabled), at: 2020)
  }
}

func workers(_ effects: [Effect], _ action: WriteAction) -> Int {
  effects.count(where: {
    if case .runWorker(action, _) = $0 {
      true
    } else {
      false
    }
  })
}

func startsTurningOff(_ effects: [Effect]) -> Bool {
  effects.contains(.writeRecord(panel))
}

@Test func turningOffWritesTheRecordThenStartsTheGuardianThenRunsAWorker() {
  var rig = Rig()
  #expect(!startsTurningOff(rig.observe(at: 0)))
  let settled = rig.observe(at: 2000)
  #expect(startsTurningOff(settled))
  #expect(workers(settled, .disable) == 0)
  let recorded = rig.send(.recordWritten(panel, succeeded: true), at: 2001)
  #expect(recorded.contains(.spawnGuardian([panel])))
  #expect(workers(recorded, .disable) == 0)
  #expect(workers(rig.send(.guardianReady, at: 2002), .disable) == 1)
}

@Test func nothingIsTurnedOffWithoutTwoSeparatedReadingsAndTheFullInterval() {
  var rig = Rig()
  rig.observe(at: 0)
  #expect(!startsTurningOff(rig.send(.tick, at: 2000)))
  #expect(startsTurningOff(rig.observe(at: 2001)))
}

@Test(arguments: [Fact.no, .unknown, .conflicting])
func anUncertainMonitorNeverStartsATurnOff(_ fact: Fact) {
  var rig = Rig()
  rig.observe(environment(external: fact), at: 0)
  #expect(!startsTurningOff(rig.observe(environment(external: fact), at: 3000)))
  #expect(rig.state.worker == nil)
}

@Test func aFinishedWorkerIsJudgedOnlyByALaterReading() {
  var rig = Rig()
  rig.reachDisable()
  rig.send(.workerFinished(.done), at: 2010)
  // Sampled before the worker finished, so it says nothing about what the worker did.
  rig.sequence += 1
  rig.send(
    .observed(.init(sequence: rig.sequence, sampledAt: 2005, environment: environment())),
    at: 2011
  )
  #expect(rig.state.worker != nil)
  rig.observe(environment(panelState: .disabled), at: 2020)
  #expect(rig.state.worker == nil)
  #expect(rig.state.failures == 0)
}

@Test func aWorkerThatReturnedButChangedNothingIsRetriedAfterABackoff() {
  var rig = Rig()
  rig.reachDisable()
  rig.send(.workerFinished(.done), at: 2010)
  // A change nothing has reported is given the whole cap before it is read as a failure, and a
  // reading is asked for at the moment that verdict could first be reached.
  let early = rig.observe(at: 2020)
  #expect(rig.state.failures == 0)
  #expect(rig.state.worker != nil)
  #expect(early.contains(.observeAt(7010)))
  let unchanged = rig.observe(at: 7010)
  #expect(rig.state.failures == 1)
  #expect(unchanged.contains(.wakeAt(7510)))
  #expect(workers(unchanged, .disable) == 0)
  #expect(workers(rig.observe(at: 7300), .disable) == 0)
  #expect(workers(rig.observe(at: 7510), .disable) == 1)
}

/// The report behind GitHub issue #9: switching back to All Monitors said "Having trouble
/// changing your laptop screen" within seconds, while the restore was on its way. The panel
/// reappears long after the call that asked for it returns, and until it does there is nothing
/// to hold against the worker, least of all another worker.
@Test func aRestoreThatTakesSecondsIsNeitherAFailureNorAskedForTwice() {
  var rig = Rig()
  rig.off()
  #expect(workers(rig.send(.selectMode(.manual), at: 3000), .enable) == 1)
  rig.send(.workerFinished(.done), at: 3100)
  // macOS is still carrying the change out, and the panel is not in the inventory yet.
  for time in stride(from: Instant(3200), to: 7000, by: 400) {
    rig.send(.displayReconfigured(inProgress: true), at: time)
    let waiting = rig.observe(environment(panelState: .disabled), at: time + 10)
    #expect(workers(waiting, .enable) == 0)
  }
  #expect(rig.state.failures == 0)
  let shown = Controller.presentation(rig.state, at: 7000)
  #expect(shown.trouble == nil)
  #expect(shown.working)
  // It arrives, late. The reading that shows it is what settles the matter.
  rig.observe(at: 7010)
  #expect(rig.state.worker == nil)
  #expect(rig.state.failures == 0)
}

/// A panel that cannot be read used to stop the controller dead: nothing was decided and nothing
/// was ever attempted again, so the screen stayed off until the Mac was restarted.
@Test func anUnreadablePanelIsTurnedBackOnWhileTheRecordSaysOneMayBeOff() {
  var rig = Rig(mode: .manual, record: panel)
  let effects = rig.observe(environment(panelState: .unknown), at: 0)
  #expect(workers(effects, .enable) == 1)
  #expect(Controller.presentation(rig.state, at: 0).unavailability == .panelUnreadable)
  #expect(Controller.presentation(rig.state, at: 0).working)
}

@Test func anUnreadablePanelWithNothingOwedIsLeftAlone() {
  var rig = Rig(mode: .manual)
  #expect(workers(rig.observe(environment(panelState: .unknown), at: 0), .enable) == 0)
  #expect(rig.state.worker == nil)
  #expect(Controller.presentation(rig.state, at: 0).unavailability != .panelUnreadable)
}

/// The record and the guardian are the only way back. Dropping them on one reading left a panel
/// that fell out of the inventory again with nothing to recognise it by and nobody to restore it.
@Test func theRecordAndTheGuardianOutliveASingleReadingSayingTheScreenIsOn() {
  var rig = Rig()
  rig.off()
  rig.send(.selectMode(.manual), at: 3000)
  rig.send(.workerFinished(.done), at: 3010)
  let first = rig.observe(at: 3020)
  #expect(!first.contains(.clearRecord))
  #expect(!first.contains(.releaseGuardian))
  #expect(rig.state.record == panel)
  #expect(rig.state.guardian == .ready)
  let held = rig.observe(at: 4000)
  #expect(!held.contains(.clearRecord))
  // Once the screen has stayed on rather than merely been seen on, nothing is owed.
  let settled = rig.observe(at: 5100)
  #expect(settled.contains(.releaseGuardian))
  #expect(settled.contains(.clearRecord))
}

@Test func aHungWorkerThatWorkedIsNotAFailure() {
  var rig = Rig()
  rig.reachDisable()
  rig.send(.workerFinished(.killed), at: 12010)
  rig.observe(environment(panelState: .disabled), at: 12020)
  #expect(rig.state.failures == 0)
  let shown = Controller.presentation(rig.state, at: 12020)
  #expect(shown.panelOff)
  #expect(shown.trouble == nil)
}

@Test func unpluggingWhileOffTurnsTheScreenOnWithoutSettling() {
  var rig = Rig()
  rig.off()
  let effects = rig.observe(environment(panelState: .disabled, external: .no), at: 2100)
  #expect(workers(effects, .enable) == 1)
}

@Test func onceTheScreenIsBackOnNothingIsOwed() {
  var rig = Rig()
  rig.off()
  rig.observe(environment(panelState: .disabled, external: .no), at: 2100)
  rig.send(.workerFinished(.done), at: 2110)
  // Seen on is not the same as kept on, and the record is the only thing an absent panel would
  // be recognised by, so it is not given up on the reading that first shows the screen back.
  #expect(!rig.observe(environment(external: .no), at: 2120).contains(.releaseGuardian))
  #expect(rig.state.record == panel)
  let effects = rig.observe(environment(external: .no), at: 4200)
  #expect(effects.contains(.releaseGuardian))
  #expect(effects.contains(.clearRecord))
  #expect(rig.state.guardian == .absent)
  rig.send(.recordCleared(succeeded: true), at: 4201)
  #expect(rig.state.record == nil)
}

@Test func noChangeStartsAroundSleep() {
  var rig = Rig()
  rig.off()
  rig.send(.willSleep, at: 2100)
  let asleep = rig.observe(
    environment(panelState: .disabled, external: .no, power: .sleeping), at: 2110
  )
  #expect(workers(asleep, .enable) == 0)
  rig.send(.waking, at: 2200)
  let awake = rig.observe(environment(panelState: .disabled, external: .no), at: 2210)
  #expect(workers(awake, .enable) == 1)
}

@Test func aClosedLidHoldsEverything() {
  var rig = Rig()
  rig.off()
  let effects = rig.observe(
    environment(panelState: .disabled, external: .no, lid: .closed), at: 2100
  )
  #expect(workers(effects, .enable) == 0)
  #expect(workers(effects, .disable) == 0)
}

@Test func aGuardianThatGoesAwayNeverLeavesTheScreenOffUnguarded() {
  var rig = Rig()
  rig.off()
  let gone = rig.send(.guardianGone, at: 2100)
  #expect(rig.state.guardian == .absent)
  #expect(workers(gone, .enable) == 0)
  #expect(workers(rig.observe(environment(panelState: .disabled), at: 2600), .enable) == 1)
}

@Test func repeatedMissesAreShownButAttemptsContinue() {
  var rig = Rig()
  rig.reachDisable()
  var now: Instant = 2010
  for _ in 0 ..< 3 {
    rig.send(.workerFinished(.failed), at: now)
    // Nothing counts against a worker until its change has had the whole window to appear.
    rig.observe(at: now + rig.state.policy.effectCap)
    now = rig.state.retryAt ?? now
    rig.observe(at: now)
  }
  #expect(rig.state.worker != nil)
  #expect(Controller.presentation(rig.state, at: now).trouble == .stillTrying)
  rig.send(.retry, at: now + 1)
  #expect(Controller.presentation(rig.state, at: now + 1).trouble == nil)
}

@Test func aRecordThatCannotBeSavedIsReportedAndRetried() {
  var rig = Rig()
  rig.observe(at: 0)
  rig.observe(at: 2000)
  let failed = rig.send(.recordWritten(panel, succeeded: false), at: 2001)
  #expect(Controller.presentation(rig.state, at: 2001).trouble == .recordNotSaved)
  #expect(failed.contains(.wakeAt(2501)))
  #expect(startsTurningOff(rig.observe(at: 2501)))
  rig.send(.recordWritten(panel, succeeded: true), at: 2502)
  #expect(Controller.presentation(rig.state, at: 2502).trouble == nil)
}

@Test func choosingAllMonitorsTurnsTheScreenBackOn() {
  var rig = Rig()
  rig.off()
  let effects = rig.send(.selectMode(.automaticPaused), at: 2100)
  #expect(effects.contains(.savePreferences(.automaticPaused)))
  #expect(workers(effects, .enable) == 1)
}

@Test func aRecordLeftByAnEarlierRunRestoresRatherThanStaysOff() {
  var rig = Rig(record: panel)
  #expect(workers(rig.observe(environment(panelState: .disabled), at: 0), .enable) == 1)
}

@Test func anUnresolvedRecordKeepsTheScreenOnUntilItIsResolved() {
  var rig = Rig()
  rig.state.recordBlocked = true
  rig.observe(at: 0)
  #expect(!startsTurningOff(rig.observe(at: 3000)))
  #expect(Controller.presentation(rig.state, at: 3000).trouble == .recordUnresolved)
  #expect(rig.send(.retry, at: 3001).contains(.reconcileRecord))
  // Resolving it is itself the moment the settled arrangement can be acted on.
  #expect(startsTurningOff(rig.send(.recordReconciled(nil, blocked: false), at: 3002)))
}

@Test func theGuardianWaitsWhileTheAppIsThereWithAMonitor() {
  var streaks = GuardianPolicy.Streaks()
  #expect(
    GuardianPolicy.decide(environment(panelState: .disabled), appAlive: true, streaks: &streaks)
      == .wait
  )
  #expect(GuardianPolicy.decide(environment(), appAlive: true, streaks: &streaks) == .wait)
  // A panel that cannot be read is the app's to sort out first, for a few readings at least.
  #expect(
    GuardianPolicy.decide(environment(panelState: .unknown), appAlive: true, streaks: &streaks)
      == .wait
  )
}

/// A panel that cannot be read is the state both halves of the safety net used to sit in for
/// ever: the app decided nothing and the guardian waited, so the screen stayed off until the Mac
/// was restarted. Nothing is owed by a guardian that was never given a panel, so this only ever
/// runs where one was.
@Test func theGuardianRestoresAPanelItCanNoLongerRead() {
  var streaks = GuardianPolicy.Streaks()
  let unreadable = environment(panelState: .unknown)
  for _ in 1 ..< GuardianPolicy.unreadableReadings {
    #expect(GuardianPolicy.decide(unreadable, appAlive: true, streaks: &streaks) == .wait)
  }
  #expect(GuardianPolicy.decide(unreadable, appAlive: true, streaks: &streaks) == .restore)
  // A reading it can read again starts the count over.
  #expect(GuardianPolicy.decide(environment(), appAlive: true, streaks: &streaks) == .wait)
  #expect(GuardianPolicy.decide(unreadable, appAlive: true, streaks: &streaks) == .wait)
  // With the app gone there is nobody else who could, so it does not wait at all.
  var alone = GuardianPolicy.Streaks()
  #expect(GuardianPolicy.decide(unreadable, appAlive: false, streaks: &alone) == .restore)
}

@Test func theGuardianRestoresOnlyOnceDangerHolds() {
  var streaks = GuardianPolicy.Streaks()
  let danger = environment(panelState: .disabled, external: .no)
  #expect(GuardianPolicy.decide(danger, appAlive: true, streaks: &streaks) == .wait)
  // A reading with a monitor in between starts the count again.
  #expect(
    GuardianPolicy.decide(environment(panelState: .disabled), appAlive: true, streaks: &streaks)
      == .wait
  )
  #expect(GuardianPolicy.decide(danger, appAlive: true, streaks: &streaks) == .wait)
  #expect(GuardianPolicy.decide(danger, appAlive: true, streaks: &streaks) == .restore)
}

@Test func theGuardianActsAtOnceWhenTheAppIsGone() {
  var streaks = GuardianPolicy.Streaks()
  #expect(
    GuardianPolicy.decide(
      environment(panelState: .disabled), appAlive: false, streaks: &streaks
    ) == .restore
  )
  #expect(GuardianPolicy.decide(environment(), appAlive: false, streaks: &streaks) == .finish)
}

/// A monitor SoloDisplay turned off is never danger: it is only ever turned off while another
/// screen is left, so nobody is blind. Only the app being gone makes it owed.
@Test func monitorsAreRestoredOnlyOnceTheAppIsGone() {
  let monitor = PanelTarget(
    displayID: 4, displayUUID: "dell", bootID: "boot-1", loginID: 42,
    kind: .external, controller: "dispext0"
  )
  #expect(
    GuardianPolicy.monitorsToRestore([monitor], appAlive: true, discharged: []).isEmpty
  )
  #expect(
    GuardianPolicy.monitorsToRestore([monitor], appAlive: false, discharged: []) == [monitor]
  )
  // Asked for once each: a monitor that is off is not in the display list at all, so there is
  // no evidence left to wait for and nothing to ask twice about.
  #expect(
    GuardianPolicy.monitorsToRestore([monitor], appAlive: false, discharged: [4]).isEmpty
  )
}
