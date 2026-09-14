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

  init(mode: Mode = .automatic, record: PanelTarget? = nil) {
    state = .init(mode: mode, record: record)
  }

  @discardableResult mutating func send(_ event: Event, at time: Instant) -> [Effect] {
    let transition = Controller.reduce(state, event, at: time)
    state = transition.state
    return transition.effects
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
  #expect(recorded.contains(.spawnGuardian(panel)))
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
  let unchanged = rig.observe(at: 2020)
  #expect(rig.state.failures == 1)
  #expect(unchanged.contains(.wakeAt(2520)))
  #expect(workers(unchanged, .disable) == 0)
  #expect(workers(rig.observe(at: 2300), .disable) == 0)
  #expect(workers(rig.observe(at: 2520), .disable) == 1)
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
  let effects = rig.observe(environment(external: .no), at: 2120)
  #expect(effects.contains(.releaseGuardian))
  #expect(effects.contains(.clearRecord))
  #expect(rig.state.guardian == .absent)
  rig.send(.recordCleared(succeeded: true), at: 2121)
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
    rig.observe(at: now + 10)
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
  var streak = 0
  #expect(
    GuardianPolicy.decide(environment(panelState: .disabled), appAlive: true, dangerStreak: &streak)
      == .wait
  )
  #expect(GuardianPolicy.decide(environment(), appAlive: true, dangerStreak: &streak) == .wait)
  #expect(
    GuardianPolicy.decide(
      environment(panelState: .unknown, external: .no), appAlive: false, dangerStreak: &streak
    ) == .wait
  )
}

@Test func theGuardianRestoresOnlyOnceDangerHolds() {
  var streak = 0
  let danger = environment(panelState: .disabled, external: .no)
  #expect(GuardianPolicy.decide(danger, appAlive: true, dangerStreak: &streak) == .wait)
  // A reading with a monitor in between starts the count again.
  #expect(
    GuardianPolicy.decide(environment(panelState: .disabled), appAlive: true, dangerStreak: &streak)
      == .wait
  )
  #expect(GuardianPolicy.decide(danger, appAlive: true, dangerStreak: &streak) == .wait)
  #expect(GuardianPolicy.decide(danger, appAlive: true, dangerStreak: &streak) == .restore)
}

@Test func theGuardianActsAtOnceWhenTheAppIsGone() {
  var streak = 0
  #expect(
    GuardianPolicy.decide(
      environment(panelState: .disabled), appAlive: false, dangerStreak: &streak
    ) == .restore
  )
  #expect(GuardianPolicy.decide(environment(), appAlive: false, dangerStreak: &streak) == .finish)
}
