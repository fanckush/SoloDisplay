/// Decides from the latest reading, never from a call returning or a deadline passing. Each event
/// updates what is known, then the controller compares what is wanted with what is observed and
/// requests only the next missing step. Nothing here is a phase that can time out.
public enum Controller {
  public static func reduce(_ previous: ControllerState, _ event: Event, at now: Instant)
    -> Transition {
    // Receipt time is monotonic. Delayed observations carry their own sampling time.
    guard now >= previous.lastReceipt else { return .init(state: previous, effects: []) }
    var state = previous
    var effects: [Effect] = []
    state.lastReceipt = now

    switch event {
    case let .observed(sample):
      guard sample.sampledAt <= now,
            sample.sequence > (state.observation?.sequence ?? 0),
            sample.sampledAt >= (state.observation?.sampledAt ?? 0)
      else {
        return .init(state: state, effects: [])
      }
      if let old = state.observation?.environment,
         old.hasSamePrerequisites(as: sample.environment) {
        if sample.sampledAt - (state.lastCountedSample ?? sample.sampledAt)
          >= state.policy.sampleSeparation {
          state.matchingSamples += 1
          state.lastCountedSample = sample.sampledAt
        }
      } else {
        state.stableSince = sample.sampledAt
        state.lastCountedSample = sample.sampledAt
        state.matchingSamples = 1
      }
      state.observation = sample
      judgeFinishedWorker(&state, at: now)
    case let .displayReconfigured(inProgress):
      state.lastDisplayChange = now
      state.displayConfiguring = inProgress
      // The new arrangement is asked again before anything is turned off. The answer itself is
      // kept: this fires for our own panel change too, and forgetting it there would restore the
      // screen, turn it off, restore it again, without end.
      state.remeasureInputSources()
    case let .selectMode(mode):
      state.mode = mode
      clearBackoff(&state)
      state.remeasureInputSources()
      effects.append(.savePreferences(mode))
    case let .preferencesSaved(succeeded):
      state.preferencesFailed = !succeeded
    case .willSleep, .waking:
      // No change starts until a fresh reading shows the Mac awake again.
      state.stableSince = nil
      state.matchingSamples = 0
      // A monitor can be switched while the Mac sleeps, so what it said before says nothing now.
      state.forgetInputSources()
      state.monitors.removeAll()
      if var sample = state.observation {
        sample.environment.power = event == .willSleep ? .sleeping : .waking
        state.observation = sample
      }
      effects.append(.observe)
    case .retry:
      clearBackoff(&state)
      if state.recordBlocked, !state.recordBusy {
        state.recordBusy = true
        effects.append(.reconcileRecord)
      }
      effects.append(.observe)
    case .tick:
      break
    case let .recordWritten(target, succeeded):
      state.recordBusy = false
      state.recordFailed = !succeeded
      if succeeded {
        state.record = target
      } else {
        backOff(&state, at: now)
      }
    case let .recordCleared(succeeded):
      state.recordBusy = false
      state.recordFailed = !succeeded
      if succeeded {
        state.record = nil
      } else {
        backOff(&state, at: now)
      }
    case let .recordReconciled(target, blocked):
      state.recordBusy = false
      state.recordBlocked = blocked
      if !blocked {
        state.record = target
      }
    case .guardianReady:
      if state.guardian == .starting {
        state.guardian = .ready
      }
    case .guardianGone:
      // A released guardian is already forgotten. Any other exit leaves disabling unguarded.
      if state.guardian != .absent {
        state.guardian = .absent
        state.guardianTargets = []
        backOff(&state, at: now)
      }
    case let .workerFinished(outcome):
      guard var worker = state.worker, worker.finishedAt == nil else { break }
      worker.finishedAt = now
      worker.outcome = outcome
      state.worker = worker
      effects.append(.observe)
    case let .inputSourcesRead(answer, monitors, sampledAt):
      readInputSources(&state, answer: answer, sampledAt: sampledAt)
      readMonitors(&state, answers: monitors, sampledAt: sampledAt)
    case let .suppressionRecorded(targets, succeeded):
      state.suppressedBusy = false
      // Only what the record actually holds. A write that failed leaves the two apart, and the
      // next pass tries again rather than turning anything off unrecorded.
      if succeeded {
        state.recordedSuppression = targets
      }
    }

    act(&state, effects: &effects, at: now)
    actOnMonitors(&state, effects: &effects, at: now)
    askInputSources(&state, effects: &effects, at: now)
    schedule(state, effects: &effects, at: now)
    return .init(state: state, effects: effects)
  }

  /// Takes one answer from the monitors. A `.unknown` answer never changes the standing one: a
  /// monitor that has gone quiet, which is what some do once switched away, must not be able to
  /// cancel a refusal. An answer that would change it has to arrive twice.
  private static func readInputSources(_ state: inout ControllerState, answer: Fact,
                                       sampledAt: Instant) {
    // A late answer from an ask already given up on is still usable, but only if it is newer.
    guard sampledAt >= (state.inputSourcesAskedAt ?? sampledAt) else { return }
    state.inputSourcesBusy = false
    state.inputSourcesAskedAt = sampledAt
    guard answer != .unknown, answer != state.inputSources else {
      state.inputSourcesPending = .unknown
      state.inputSourcesAgreeing = 0
      state.inputSourcesDueAt = sampledAt + state.policy.inputSourceInterval
      return
    }
    if answer == state.inputSourcesPending {
      state.inputSourcesAgreeing += 1
    } else {
      state.inputSourcesPending = answer
      state.inputSourcesAgreeing = 1
    }
    guard state.inputSourcesAgreeing >= state.policy.inputSourceReadings else {
      state.inputSourcesDueAt = sampledAt + state.policy.inputSourceConfirm
      return
    }
    state.inputSources = answer
    state.inputSourcesPending = .unknown
    state.inputSourcesAgreeing = 0
    state.inputSourcesDueAt = sampledAt + state.policy.inputSourceInterval
  }

  /// Takes each monitor's own answer. Same rule as the arrangement's: nothing said changes
  /// nothing, and an answer that would change something has to arrive twice.
  private static func readMonitors(
    _ state: inout ControllerState, answers: [MonitorAnswer]?, sampledAt: Instant
  ) {
    // No sweep answered, so nothing was learned. Forgetting here would drop a monitor this app
    // has turned off, leaving it off with nobody left who knows it is owed.
    guard let answers else { return }
    for answer in answers {
      var verdict = state.monitors[answer.controller] ?? .init()
      verdict.lastAnswered = sampledAt
      if answer.shown == .unknown || answer.shown == verdict.shown {
        verdict.pending = .unknown
        verdict.agreeing = 0
      } else if answer.shown == verdict.pending {
        verdict.agreeing += 1
        if verdict.agreeing >= state.policy.inputSourceReadings {
          verdict.shown = answer.shown
          verdict.pending = .unknown
          verdict.agreeing = 0
        }
      } else {
        verdict.pending = answer.shown
        verdict.agreeing = 1
      }
      state.monitors[answer.controller] = verdict
    }
    // An endpoint that was not answered for is a monitor that has gone.
    let live = Set(answers.map(\.controller))
    state.monitors = state.monitors.filter { live.contains($0.key) }
    state.suppressed.removeAll {
      guard let controller = $0.controller else { return true }
      return !live.contains(controller)
    }
  }

  /// Turns a monitor off once it has said twice that it is showing another machine, and turns it
  /// back on as soon as anything says it should be. Turning one back on is always safe, so it is
  /// tried first and on far weaker evidence than turning one off.
  /// Turns a monitor off once it has said twice that it is showing another machine, and turns it
  /// back on as soon as anything says it should be. The laptop screen comes first in everything:
  /// there is one worker at a time, and a monitor must never hold the slot the screen needs.
  private static func actOnMonitors(
    _ state: inout ControllerState, effects: inout [Effect], at now: Instant
  ) {
    guard state.worker == nil, !state.recordBusy, !state.suppressedBusy,
          let environment = state.observation?.environment,
          // Nothing here runs while the laptop screen is not where it should be. A monitor that
          // cannot be reached would otherwise keep the one worker slot, and the screen with it.
          panelSettled(state, environment: environment, at: now)
    else { return }
    // What is owed and what the record says are brought back together before anything moves, so
    // nothing is ever off that the record does not name.
    if state.suppressed != state.recordedSuppression {
      state.suppressedBusy = true
      effects.append(.recordSuppression(state.suppressed))
      return
    }
    if let target = monitorToRestore(state, environment: environment, at: now) {
      state.worker = .init(action: .enable, target: target, startedAt: now)
      effects.append(.runWorker(.enable, target))
      return
    }
    if let target = monitorToSuppress(state, environment: environment, at: now) {
      state.suppressed.append(target)
      return
    }
    guard !state.suppressed.isEmpty else { return }
    if state.guardian == .absent {
      state.guardian = .starting
      // Spawned holding them, so there is no moment where it is running and does not know.
      state.guardianTargets = state.ownedTargets
      effects.append(.spawnGuardian(state.ownedTargets))
      return
    }
    guard state.guardian == .ready else { return }
    if state.guardianTargets != state.ownedTargets {
      // Nothing is ever off that the guardian has not been told about.
      state.guardianTargets = state.ownedTargets
      effects.append(.updateGuardian(state.ownedTargets))
      return
    }
    // Whatever is owed but still in the inventory has not been turned off yet.
    guard let target = state.suppressed.first(where: { owed in
      environment.externals.contains {
        $0.target.displayUUID == owed.displayUUID && !$0.suppressed
      }
    }) else { return }
    state.worker = .init(action: .disable, target: target, startedAt: now)
    effects.append(.runWorker(.disable, target))
  }

  /// The laptop screen is where it should be, or nothing about it is being decided right now.
  static func panelSettled(
    _ state: ControllerState, environment: Environment, at now: Instant
  ) -> Bool {
    guard let wanted = desired(state, at: now) else { return true }
    return wanted == environment.panelState
  }

  /// Every reason a monitor should come back. Any one of them is enough: a monitor that is on is
  /// the state everything starts in, and the worst it costs is a desktop nobody is looking at.
  static func monitorToRestore(
    _ state: ControllerState, environment: Environment, at now: Instant
  ) -> PanelTarget? {
    state.suppressed.first { target in
      guard let controller = target.controller else { return true }
      let verdict = state.monitors[controller]
      // One answer is enough here. Turning a monitor back on is always safe, and the worst a
      // wrong one costs is a desktop nobody is looking at, which is where everything started.
      if verdict?.shown == .thisMac || verdict?.pending == .thisMac {
        return true
      }
      if environment.power != .awake || environment.foregroundSession != .yes {
        return true
      }
      // Nothing left to look at. One screen left is the point of turning a monitor off, so the
      // net is at zero rather than at one: treating one as danger would undo every suppression
      // the instant it landed, which is what it did on hardware on 2026-09-20.
      if environment.visibleDisplays == 0 {
        return true
      }
      if state.recordBlocked {
        return true
      }
      // A monitor that has answered nothing for a long time cannot be confirmed invisible.
      return now - (verdict?.lastAnswered ?? now) >= state.policy.monitorSilence
    }
  }

  /// A monitor is turned off only on its own word, twice, and only while another screen is left.
  static func monitorToSuppress(
    _ state: ControllerState, environment: Environment, at now: Instant
  ) -> PanelTarget? {
    guard environment.visibilityExpected, !state.recordBlocked,
          environment.visibleDisplays >= 2, isSettled(state, at: now)
    else { return nil }
    return environment.externals.first { candidate in
      // Owed already. The inventory is a reading and lags by one, so this is asked of what is
      // owed rather than of what was last seen.
      guard !state.suppressed.contains(where: {
        $0.displayUUID == candidate.target.displayUUID
      })
      else { return false }
      guard candidate.suppressible, !candidate.suppressed,
            let controller = candidate.target.controller,
            let verdict = state.monitors[controller], verdict.shown == .otherMachine
      else { return false }
      // Left alone for a while after it was last changed, so two rules disagreeing show up as
      // slowness rather than as a screen going on and off.
      guard let changed = verdict.lastChanged else { return true }
      return now - changed >= state.policy.monitorSettleFloor
    }?.target
  }

  /// Asks the monitors what they are showing: once before anything is turned off, and then every
  /// interval for as long as the answer could still change what happens.
  private static func askInputSources(_ state: inout ControllerState, effects: inout [Effect],
                                      at now: Instant) {
    // Asked in either arrangement: a monitor showing another machine is just as invisible when
    // the laptop screen is on, and a monitor this app turned off has to be asked to get it back.
    guard !state.inputSourcesBusy,
          let environment = state.observation?.environment, environment.visibilityExpected,
          environment.nativeExternalAvailable == .yes || !state.suppressed.isEmpty,
          environment.panelState != .unknown
    else { return }
    // While the screen is off, or while a refusal stands, keep asking so it can be lifted again.
    // Otherwise ask once per settling window, which is what holds the first turn-off back.
    let due = environment.panelState == .disabled || state.inputRefusal
      || !state.suppressed.isEmpty || !state.wantsOff
      ? now >= (state.inputSourcesDueAt ?? now)
      : !inputAsked(state, at: now)
    guard due else { return }
    state.inputSourcesBusy = true
    effects.append(.readInputSources)
  }

  /// The monitors have been asked since this arrangement settled. What they said may be nothing;
  /// what matters is that the question was put after the change. An ask that never comes back
  /// stops holding the decision after `inputSourceDeadline`, which is how a Mac whose monitors
  /// cannot answer at all keeps behaving exactly as it did before.
  static func inputAsked(_ state: ControllerState, at now: Instant) -> Bool {
    guard let since = state.stableSince else { return false }
    if let asked = state.inputSourcesAskedAt, asked >= since {
      return true
    }
    return state.inputSourcesBusy && now - since >= state.policy.inputSourceDeadline
  }

  /// What the laptop screen should be, or nil when nothing should be changed right now: the Mac
  /// is asleep or closed, the panel cannot be identified, or an arrangement is still settling.
  static func desired(_ state: ControllerState, at now: Instant) -> PanelState? {
    guard let environment = state.observation?.environment, environment.visibilityExpected,
          environment.panel != nil, environment.panelState != .unknown
    else { return nil }
    // A monitor showing another machine is a reason to refuse, never a reason to act. While the
    // screen is on, one answer is enough to withhold, because withholding changes nothing. While
    // it is off, putting it back is a change, so that waits for the answer to repeat.
    let monitorRefuses = environment.panelState == .disabled
      ? state.inputDemand
      : state.inputRefusal
    guard state.wantsOff, !state.recordBlocked,
          environment.prerequisitesMet, !monitorRefuses else { return .enabled }
    if environment.panelState == .disabled {
      // Never stay off without a guardian that would bring the screen back.
      return state.guardian == .absent ? .enabled : .disabled
    }
    // Nothing is turned off before the monitors have been asked what they are showing.
    guard inputAsked(state, at: now) else { return nil }
    return isSettled(state, at: now) ? .disabled : nil
  }

  /// Requests the one next step toward the wanted state. Turning off needs the record, then the
  /// guardian, then the worker, each only once the step before it has landed.
  private static func act(_ state: inout ControllerState, effects: inout [Effect],
                          at now: Instant) {
    guard state.worker == nil, !state.recordBusy, now >= (state.retryAt ?? now),
          let environment = state.observation?.environment, let panel = environment.panel,
          let desired = desired(state, at: now)
    else { return }
    switch (desired, environment.panelState) {
    case (.disabled, .enabled):
      if state.record != panel {
        state.recordBusy = true
        effects.append(.writeRecord(panel))
      } else if state.guardian == .absent {
        state.guardian = .starting
        state.guardianTargets = state.ownedTargets
        effects.append(.spawnGuardian(state.ownedTargets))
      } else if state.guardian == .ready, state.guardianTargets != state.ownedTargets {
        // A guardian started for a monitor knows nothing about this panel yet, and one that does
        // not know cannot give it back. It is told before the screen goes off, never after.
        state.guardianTargets = state.ownedTargets
        effects.append(.updateGuardian(state.ownedTargets))
      } else if state.guardian == .ready {
        state.worker = .init(action: .disable, target: panel, startedAt: now)
        effects.append(.runWorker(.disable, panel))
      }
    case (.enabled, .disabled):
      state.worker = .init(action: .enable, target: panel, startedAt: now)
      effects.append(.runWorker(.enable, panel))
    case (.enabled, .enabled):
      // The screen is on and staying on, so nothing is owed any more. A monitor that is off is
      // still owed, though, and the guardian is the only thing that would give it back.
      if state.guardian != .absent, state.suppressed.isEmpty {
        state.guardian = .absent
        state.guardianTargets = []
        effects.append(.releaseGuardian)
      }
      if state.record != nil {
        state.recordBusy = true
        effects.append(.clearRecord)
      }
    default:
      break
    }
  }

  /// A finished worker is judged only by a reading sampled after it finished. Its exit status
  /// says nothing about the display: a hung call can have worked, and a returned one can have not.
  private static func judgeFinishedWorker(_ state: inout ControllerState, at now: Instant) {
    guard let worker = state.worker, let finished = worker.finishedAt,
          let sample = state.observation, sample.sampledAt >= finished
    else { return }
    state.worker = nil
    if worker.target.kind == .external {
      judgeFinishedMonitorWorker(&state, worker: worker, sample: sample, at: now)
      return
    }
    let wanted: PanelState = worker.action == .disable ? .disabled : .enabled
    if sample.environment.panelState == wanted {
      clearBackoff(&state)
    } else {
      backOff(&state, at: now)
    }
  }

  /// A monitor that was turned off leaves the inventory; one that came back is in it again.
  /// The call returning says nothing, the same as everywhere else.
  private static func judgeFinishedMonitorWorker(
    _ state: inout ControllerState, worker: RunningWorker, sample: Observation, at now: Instant
  ) {
    let live = sample.environment.externals.contains {
      $0.target.displayUUID == worker.target.displayUUID && !$0.suppressed
    }
    let landed = worker.action == .disable ? !live : live
    guard !landed else {
      state.monitorAttempts[worker.target.displayUUID] = nil
      if let controller = worker.target.controller {
        var verdict = state.monitors[controller] ?? .init()
        verdict.lastChanged = now
        state.monitors[controller] = verdict
      }
      if worker.action == .enable {
        state.suppressed.removeAll { $0.displayUUID == worker.target.displayUUID }
      }
      return
    }
    // A monitor that will not change is given up on rather than tried for ever. The usual cause
    // is a monitor that has been unplugged, whose ID now names nothing. Its own backoff is never
    // the laptop screen's: the screen must not wait behind a monitor that cannot be reached.
    let attempts = (state.monitorAttempts[worker.target.displayUUID] ?? 0) + 1
    state.monitorAttempts[worker.target.displayUUID] = attempts
    guard attempts >= state.policy.monitorAttempts else { return }
    state.monitorAttempts[worker.target.displayUUID] = nil
    state.suppressed.removeAll { $0.displayUUID == worker.target.displayUUID }
  }

  private static func backOff(_ state: inout ControllerState, at now: Instant) {
    state.failures += 1
    let delays = state.policy.retryDelays
    let delay = delays.isEmpty ? 0 : delays[min(state.failures, delays.count) - 1]
    state.retryAt = now + delay
  }

  private static func clearBackoff(_ state: inout ControllerState) {
    state.failures = 0
    state.retryAt = nil
  }

  private static func schedule(_ state: ControllerState, effects: inout [Effect], at now: Instant) {
    // Read at the moment settling could complete, rather than when a periodic refresh happens to.
    if state.wantsOff, state.worker == nil, let sample = state.observation,
       sample.environment.panelState == .enabled, let check = nextSettleCheck(state),
       check > sample.sampledAt {
      effects.append(.observeAt(check))
    }
    if let retryAt = state.retryAt, retryAt > now {
      effects.append(.wakeAt(retryAt))
    }
    // Asking again is on its own clock, so it needs its own wake rather than the periodic one.
    if !state.inputSourcesBusy, let due = state.inputSourcesDueAt, due > now {
      effects.append(.wakeAt(due))
    }
  }

  /// Two separated readings agree, and the arrangement has stopped changing. When macOS reported
  /// a reconfiguration that explains this arrangement, stopping means a reading taken after
  /// `quietFor` without another report, or `settleCap` if the reports never go quiet. Anything
  /// else, such as a lid or session change, still needs the full `stableFor`.
  static func isSettled(_ state: ControllerState, at now: Instant) -> Bool {
    guard state.matchingSamples >= 2, let since = state.stableSince,
          let sample = state.observation
    else { return false }
    let policy = state.policy
    guard let change = state.lastDisplayChange, change >= since - policy.quietFor else {
      return now - since >= policy.stableFor
    }
    if !state.displayConfiguring, sample.sampledAt >= change + policy.quietFor {
      return true
    }
    return now - since >= policy.settleCap
  }

  /// The first instant a new reading could show the arrangement as settled.
  static func nextSettleCheck(_ state: ControllerState) -> Instant? {
    guard let since = state.stableSince, state.observation != nil else { return nil }
    let policy = state.policy
    let ready: Instant = if let change = state.lastDisplayChange,
                            change >= since - policy.quietFor {
      state.displayConfiguring
        ? since + policy.settleCap
        : min(change + policy.quietFor, since + policy.settleCap)
    } else {
      since + policy.stableFor
    }
    guard state.matchingSamples < 2 else { return ready }
    return max(ready, (state.lastCountedSample ?? since) + policy.sampleSeparation)
  }
}

public extension Controller {
  /// The first reason the laptop screen cannot be off, in the order the controller checks them.
  static func unavailability(_ state: ControllerState, at now: Instant) -> Unavailability? {
    guard let environment = state.observation?.environment else { return .noObservation }
    if environment.panel == nil {
      return .noConfirmedPanel
    }
    if environment.lid != .open {
      return .lidClosed
    }
    if environment.power != .awake {
      return .notAwake
    }
    if environment.foregroundSession != .yes {
      return .sessionNotForeground
    }
    if environment.supportedTopology != .yes {
      return .unsupportedTopology
    }
    if environment.nativeExternalAvailable != .yes {
      return .noNativeExternal
    }
    if environment.panelState == .disabled ? state.inputDemand : state.inputRefusal {
      return .monitorShowsAnotherMachine
    }
    if environment.panelState == .disabled {
      return nil
    }
    // Waiting for the monitors to answer is a moment, like settling, and reads as one.
    return isSettled(state, at: now) && inputAsked(state, at: now) ? nil : .settling
  }

  static func trouble(_ state: ControllerState) -> Trouble? {
    if state.recordBlocked {
      return .recordUnresolved
    }
    if state.recordFailed {
      return .recordNotSaved
    }
    if state.failures >= state.policy.troubleAfter {
      return .stillTrying
    }
    return state.preferencesFailed ? .preferencesNotSaved : nil
  }

  static func presentation(_ state: ControllerState, at now: Instant) -> Presentation {
    let actual = state.observation?.environment.panelState
    let heading = desired(state, at: now)
    let working = state.worker != nil || state.guardian == .starting
      || (heading == .disabled && actual == .enabled)
      || (heading == .enabled && actual == .disabled)
    var shown = Presentation(
      wantsInternalOff: state.wantsOff, panelOff: actual == .disabled, working: working,
      trouble: trouble(state), unavailability: unavailability(state, at: now)
    )
    shown.suppressedMonitors = state.suppressed.count
    return shown
  }
}
