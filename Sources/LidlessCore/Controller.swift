public enum Controller {
  public static func reduce(_ previous: ControllerState, _ event: Event, at now: Instant)
    -> Transition
  {
    // Receipt time is monotonic. Delayed observations carry their own sampling time.
    guard now >= previous.lastReceipt else { return .init(state: previous, effects: []) }
    var state = previous
    var effects: [Effect] = []
    state.lastReceipt = now

    switch event {
    case .observed(let sample):
      guard sample.sampledAt <= now,
        sample.sequence > (state.observation?.sequence ?? 0),
        sample.sampledAt >= (state.observation?.sampledAt ?? 0)
      else {
        return .init(state: state, effects: [])
      }
      let old = state.observation?.environment
      let current = sample.environment
      if let old, old.hasSamePrerequisites(as: current) {
        if sample.sampledAt - (state.lastCountedSample ?? sample.sampledAt)
          >= state.policy.sampleSeparation
        {
          state.matchingSamples += 1
          state.lastCountedSample = sample.sampledAt
        }
      } else {
        state.stableSince = sample.sampledAt
        state.lastCountedSample = sample.sampledAt
        state.matchingSamples = 1
      }
      state.observation = sample
      if !current.prerequisitesMet { state.manualRequest = false }
      if old?.visibilityExpected != true, current.visibilityExpected,
        state.operation?.phase == .verifying
      {
        state.operation?.deadline = now + state.policy.operationTimeout
      }

      if let owned = state.ownership, let panel = current.panel, panel != owned.target {
        state.fault = .identityChanged
      }

      // Only a post-return observation verifies a completed operation.
      if let op = state.operation, op.phase == .verifying,
        sample.sequence > op.issuedSequence, current.panel == op.target
      {
        if op.kind == .disable && current.panelState == .disabled {
          state.operation = nil
        } else if op.kind == .restore && current.panelState == .enabled {
          state.operation = nil
          releaseOwnership(&state, effects: &effects)
        }
      } else if state.operation == nil, state.ownership != nil, !state.pendingClear,
        current.panel == state.ownership?.target, current.panelState == .enabled
      {
        // Someone else (including macOS) restored the panel. Do not fight that change.
        releaseOwnership(&state, effects: &effects)
        state.fault = .conflictingController
        state.manualRequest = false
      }

    case .selectMode(let mode):
      state.mode = mode
      state.manualRequest = false
      effects.append(.savePreferences(mode))
    case .manualOff:
      if state.mode == .manual { state.manualRequest = true }
    case .keepOn:
      state.manualRequest = false
      if state.mode != .manual {
        state.mode = .automaticPaused
        effects.append(.savePreferences(.automaticPaused))
      }
    case .retry:
      if state.operation == nil {
        state.fault = nil
        state.restoreAttempts = 0
        state.retryAt = nil
        state.stableSince = now
        state.matchingSamples = 0
        effects.append(.observe)
        // An unresolved record is retried explicitly. Retry never forgets one.
        if state.pendingClear { effects.append(.clearOwnership) }
      }
    case .willSleep, .waking:
      state.manualRequest = false
      state.stableSince = nil
      state.matchingSamples = 0
      if var sample = state.observation {
        sample.environment.power = event == .willSleep ? .sleeping : .waking
        state.observation = sample
      }
      effects.append(.observe)
    case .quit:
      state.shuttingDown = true
      state.manualRequest = false
    case .journalSaved(let id, let succeeded):
      guard var op = state.operation, op.id == id, op.phase == .journaling else {
        return .init(state: state, effects: [])
      }
      if !succeeded {
        state.operation = nil
        state.fault = .journalFailed
        state.manualRequest = false
      } else {
        // A durable record always becomes tracked ownership, even when the attempt stops here.
        state.ownership = .init(target: op.target, operationID: op.id)
        if mayDisable(state, at: now), state.observation?.environment.panel == op.target {
          op.phase = .arming
          op.deadline = now + state.policy.operationTimeout
          state.operation = op
          effects.append(
            .armProtection(
              operationID: op.id, ownership: .init(target: op.target, operationID: op.id)))
        } else {
          state.operation = nil
          releaseOwnership(&state, effects: &effects)
        }
      }
    case .protectionArmed(let id, let succeeded):
      guard var op = state.operation, op.id == id, op.phase == .arming else {
        return .init(state: state, effects: [])
      }
      // No display request is issued before this phase completes, so a failure here is
      // positively known to have changed nothing. That is why the record can be cleared.
      if !succeeded {
        state.operation = nil
        state.fault = .protectionUnavailable
        state.manualRequest = false
        releaseOwnership(&state, effects: &effects)
      } else if mayDisable(state, at: now), state.observation?.environment.panel == op.target {
        op.phase = .submitted
        op.deadline = now + state.policy.operationTimeout
        op.issuedSequence = state.observation?.sequence ?? 0
        state.operation = op
        effects.append(.setPanelEnabled(operationID: op.id, target: op.target, enabled: false))
      } else {
        state.operation = nil
        releaseOwnership(&state, effects: &effects)
      }
    case .protectionAvailable(let available):
      state.protectionAvailable = available
      // Losing the helper while a panel may be off means restore now and stop disabling.
      if !available, state.ownership != nil, !state.pendingClear {
        state.fault = .protectionLost
        state.manualRequest = false
      }
    case .ownershipCleared(let succeeded):
      guard state.pendingClear else { return .init(state: state, effects: []) }
      if succeeded {
        state.pendingClear = false
        state.ownership = nil
        state.restoreAttempts = 0
        state.retryAt = nil
      } else {
        // Keep the record and the ownership it stands for. Forgetting it is the worse failure.
        state.fault = .ownershipClearFailed
        state.manualRequest = false
      }
    case .operationRefused(let id):
      guard let op = state.operation, op.id == id, op.phase == .submitted || op.phase == .stalled
      else {
        return .init(state: state, effects: [])
      }
      // Nothing was sent, so a disable leaves nothing to undo and its record can go.
      state.operation = nil
      state.fault = .operationRefused
      state.manualRequest = false
      if op.kind == .disable {
        releaseOwnership(&state, effects: &effects)
      } else {
        state.restoreAttempts -= 1
        scheduleRetry(&state, at: now, effects: &effects)
      }
      effects.append(.observe)
    case .operationReturned(let id, let succeeded):
      guard var op = state.operation, op.id == id,
        op.phase == .submitted || op.phase == .stalled
      else {
        return .init(state: state, effects: [])
      }
      // An API error may still leave side effects. Never drop ownership on error.
      if !succeeded {
        state.operation = nil
        state.fault = .operationFailed
        state.manualRequest = false
        if op.kind == .restore { scheduleRetry(&state, at: now, effects: &effects) }
      } else {
        op.phase = .verifying
        op.issuedSequence = state.observation?.sequence ?? 0
        op.deadline = now + state.policy.operationTimeout
        state.operation = op
      }
      effects.append(.observe)
    case .tick:
      break
    }

    // A returned disable call is no longer a writer. Restoration takes priority over
    // completing its verification when sleep, user intent, or external evidence changes.
    if let op = state.operation, op.kind == .disable, op.phase == .verifying,
      !state.wantsOff || !mayRemainDisabled(state, at: now)
    {
      state.operation = nil
    }

    if let op = state.operation, now >= op.deadline {
      switch op.phase {
      case .journaling:
        // The storage write can still complete. Keep the operation until its acknowledgement.
        state.fault = .journalFailed
        state.manualRequest = false
      case .arming:
        // The helper never answered, and nothing was written. Clear the record and fault.
        state.operation = nil
        state.fault = .protectionUnavailable
        state.manualRequest = false
        releaseOwnership(&state, effects: &effects)
      case .submitted:
        state.operation?.phase = .stalled
        state.fault = .operationTimedOut
        state.manualRequest = false
        effects.append(.writerUnresponsive(operationID: op.id))
      case .verifying:
        // Sleeping/closed hardware cannot prove visibility. Resume verification when awake.
        if state.observation?.environment.visibilityExpected == true && isFresh(state, at: now) {
          state.operation = nil
          state.fault = .verificationFailed
          state.manualRequest = false
          if op.kind == .restore { scheduleRetry(&state, at: now, effects: &effects) }
        }
      case .stalled:
        break
      }
    }

    if state.operation == nil, !state.pendingClear {
      if let ownership = state.ownership {
        let shouldRestore =
          !state.wantsOff || !mayRemainDisabled(state, at: now)
          || state.observation?.environment.panelState == .unknown
        let identityMatches = state.observation?.environment.panel == ownership.target
        if shouldRestore && identityMatches && state.fault != .identityChanged,
          state.restoreAttempts <= state.policy.restoreRetryDelays.count,
          now >= (state.retryAt ?? 0)
        {
          let op = newOperation(&state, kind: .restore, target: ownership.target, at: now)
          state.restoreAttempts += 1
          state.retryAt = nil
          state.operation = op
          effects.append(.setPanelEnabled(operationID: op.id, target: op.target, enabled: true))
        }
      } else if mayDisable(state, at: now), let target = state.observation?.environment.panel {
        var op = newOperation(&state, kind: .disable, target: target, at: now)
        op.phase = .journaling
        state.operation = op
        effects.append(.saveOwnership(.init(target: target, operationID: op.id)))
      }
    }

    if let op = state.operation, op.phase != .stalled, op.deadline > now {
      effects.append(.wakeAt(op.deadline))
    }
    if let sample = state.observation, state.ownership != nil || state.wantsOff {
      let expiry = sample.sampledAt + state.policy.evidenceLifetime + 1
      if expiry > now { effects.append(.wakeAt(expiry)) }
    }
    if state.wantsOff, state.operation == nil, state.ownership == nil,
      let since = state.stableSince, since + state.policy.stableFor > now
    {
      effects.append(.wakeAt(since + state.policy.stableFor))
    }
    if state.shuttingDown && state.operation == nil && state.ownership == nil
      && !state.pendingClear
    {
      effects.append(.exitReady)
    }
    return .init(state: state, effects: effects)
  }

  public static func mayDisable(_ state: ControllerState, at now: Instant) -> Bool {
    guard state.wantsOff, state.protectionAvailable, !state.pendingClear,
      isFresh(state, at: now), let sample = state.observation,
      sample.environment.prerequisitesMet, sample.environment.panelState == .enabled,
      state.matchingSamples >= 2, let stableSince = state.stableSince
    else { return false }
    return now - stableSince >= state.policy.stableFor
  }

  private static func mayRemainDisabled(_ state: ControllerState, at now: Instant) -> Bool {
    isFresh(state, at: now) && state.observation?.environment.prerequisitesMet == true
  }

  private static func isFresh(_ state: ControllerState, at now: Instant) -> Bool {
    guard let sample = state.observation else { return false }
    return now >= sample.sampledAt && now - sample.sampledAt <= state.policy.evidenceLifetime
  }

  private static func newOperation(
    _ state: inout ControllerState, kind: OperationKind,
    target: PanelTarget, at now: Instant
  ) -> Operation {
    let id = state.nextOperationID
    state.nextOperationID += 1
    return .init(
      id: id, kind: kind, target: target, phase: .submitted,
      issuedSequence: state.observation?.sequence ?? 0,
      deadline: now + state.policy.operationTimeout)
  }

  /// Ownership survives until the durable record is actually gone. Only `.ownershipCleared`
  /// releases it, so a failed clear cannot quietly turn into a forgotten suppressed panel.
  private static func releaseOwnership(_ state: inout ControllerState, effects: inout [Effect]) {
    guard !state.pendingClear else { return }
    state.restoreAttempts = 0
    state.retryAt = nil
    state.pendingClear = true
    effects.append(.clearOwnership)
    effects.append(.releaseProtection)
  }

  private static func scheduleRetry(
    _ state: inout ControllerState, at now: Instant, effects: inout [Effect]
  ) {
    let index = state.restoreAttempts - 1
    if state.policy.restoreRetryDelays.indices.contains(index) {
      state.retryAt = now + state.policy.restoreRetryDelays[index]
      effects.append(.wakeAt(state.retryAt!))
    } else {
      state.fault = .recoveryExhausted
    }
  }
}
