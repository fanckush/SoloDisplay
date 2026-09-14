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
    case let .selectMode(mode):
      state.mode = mode
      clearBackoff(&state)
      effects.append(.savePreferences(mode))
    case let .preferencesSaved(succeeded):
      state.preferencesFailed = !succeeded
    case .willSleep, .waking:
      // No change starts until a fresh reading shows the Mac awake again.
      state.stableSince = nil
      state.matchingSamples = 0
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
        backOff(&state, at: now)
      }
    case let .workerFinished(outcome):
      guard var worker = state.worker, worker.finishedAt == nil else { break }
      worker.finishedAt = now
      worker.outcome = outcome
      state.worker = worker
      effects.append(.observe)
    }

    act(&state, effects: &effects, at: now)
    schedule(state, effects: &effects, at: now)
    return .init(state: state, effects: effects)
  }

  /// What the laptop screen should be, or nil when nothing should be changed right now: the Mac
  /// is asleep or closed, the panel cannot be identified, or an arrangement is still settling.
  static func desired(_ state: ControllerState, at now: Instant) -> PanelState? {
    guard let environment = state.observation?.environment, environment.visibilityExpected,
          environment.panel != nil, environment.panelState != .unknown
    else { return nil }
    guard state.wantsOff, !state.recordBlocked,
          environment.prerequisitesMet else { return .enabled }
    if environment.panelState == .disabled {
      // Never stay off without a guardian that would bring the screen back.
      return state.guardian == .absent ? .enabled : .disabled
    }
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
        effects.append(.spawnGuardian(panel))
      } else if state.guardian == .ready {
        state.worker = .init(action: .disable, target: panel, startedAt: now)
        effects.append(.runWorker(.disable, panel))
      }
    case (.enabled, .disabled):
      state.worker = .init(action: .enable, target: panel, startedAt: now)
      effects.append(.runWorker(.enable, panel))
    case (.enabled, .enabled):
      // The screen is on and staying on, so nothing is owed any more.
      if state.guardian != .absent {
        state.guardian = .absent
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
    let wanted: PanelState = worker.action == .disable ? .disabled : .enabled
    if sample.environment.panelState == wanted {
      clearBackoff(&state)
    } else {
      backOff(&state, at: now)
    }
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
    if environment.panelState == .disabled {
      return nil
    }
    return isSettled(state, at: now) ? nil : .settling
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
    return .init(
      wantsInternalOff: state.wantsOff, panelOff: actual == .disabled, working: working,
      trouble: trouble(state), unavailability: unavailability(state, at: now)
    )
  }
}
