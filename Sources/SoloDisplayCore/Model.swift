/// Time supplied by the executor, in monotonic milliseconds. No wall clock in the core.
public typealias Instant = Int64

public enum Mode: String, Codable, Sendable { case manual, automatic, automaticPaused }
public enum Fact: String, Codable, Sendable { case yes, no, unknown, conflicting }
public enum Power: String, Codable, Sendable { case awake, sleeping, waking, unknown }
public enum Lid: String, Codable, Sendable { case open, closed, absent, unknown }
public enum PanelState: String, Codable, Sendable { case enabled, disabled, unknown }

/// Valid only within the recorded boot and GUI login session. UUID alone is not authority.
public struct PanelTarget: Codable, Equatable, Sendable {
  public var displayID: UInt32
  public var displayUUID: String
  public var bootID: String
  public var loginID: UInt32

  public init(displayID: UInt32, displayUUID: String, bootID: String, loginID: UInt32) {
    self.displayID = displayID
    self.displayUUID = displayUUID
    self.bootID = bootID
    self.loginID = loginID
  }
}

public struct Environment: Codable, Equatable, Sendable {
  public var panel: PanelTarget?
  public var panelState: PanelState
  public var power: Power
  public var lid: Lid
  public var foregroundSession: Fact
  public var nativeExternalAvailable: Fact
  public var supportedTopology: Fact
  /// A found private symbol does not establish this contract. Set only after backend validation.
  public var backendValidated: Fact
  public var restorationMatches: Fact = .yes

  public init(
    panel: PanelTarget?, panelState: PanelState, power: Power, lid: Lid,
    foregroundSession: Fact, nativeExternalAvailable: Fact,
    supportedTopology: Fact, backendValidated: Fact
  ) {
    self.panel = panel
    self.panelState = panelState
    self.power = power
    self.lid = lid
    self.foregroundSession = foregroundSession
    self.nativeExternalAvailable = nativeExternalAvailable
    self.supportedTopology = supportedTopology
    self.backendValidated = backendValidated
  }

  /// Changes produced by our own panel operation do not restart external stability timing.
  func hasSamePrerequisites(as other: Environment) -> Bool {
    panel == other.panel && power == other.power && lid == other.lid
      && foregroundSession == other.foregroundSession
      && nativeExternalAvailable == other.nativeExternalAvailable
      && supportedTopology == other.supportedTopology && backendValidated == other.backendValidated
  }

  /// Public because the executor must repeat this check immediately before it writes.
  ///
  /// `backendValidated` is deliberately not a condition here. It records that a verified off and
  /// on round trip has happened on this Mac and this macOS build, which is worth knowing and is
  /// still written, but requiring it first meant a fresh install could never make the round trip
  /// that would produce it. Choosing External Only is an explicit, attended request; the journal,
  /// the protection lease and the recovery worker are what stand behind an attempt that fails.
  public var prerequisitesMet: Bool {
    panel != nil && power == .awake && lid == .open && foregroundSession == .yes
      && nativeExternalAvailable == .yes && supportedTopology == .yes
  }

  var visibilityExpected: Bool {
    power == .awake && lid == .open && foregroundSession == .yes
  }
}

public struct Observation: Codable, Equatable, Sendable {
  public var sequence: UInt64
  public var sampledAt: Instant
  public var environment: Environment

  public init(sequence: UInt64, sampledAt: Instant, environment: Environment) {
    self.sequence = sequence
    self.sampledAt = sampledAt
    self.environment = environment
  }
}

public enum OperationKind: String, Codable, Sendable { case disable, restore }
/// Disabling walks these in order: durable ownership, an acknowledged protection lease, the
/// call itself, then separate verification. Nothing skips ahead on a hopeful assumption.
public enum OperationPhase: String, Codable, Sendable {
  case journaling, arming, submitted, verifying, stalled
}

public struct Operation: Codable, Equatable, Sendable {
  public var id: UInt64
  public var kind: OperationKind
  public var target: PanelTarget
  public var phase: OperationPhase
  public var issuedSequence: UInt64
  public var deadline: Instant
  /// Optional so replay exports from before it existed still decode.
  public var startedAt: Instant?
}

public struct Ownership: Codable, Equatable, Sendable {
  public var target: PanelTarget
  public var operationID: UInt64

  public init(target: PanelTarget, operationID: UInt64) {
    self.target = target
    self.operationID = operationID
  }
}

public enum Fault: String, Codable, CaseIterable, Sendable {
  case journalFailed, operationFailed, operationTimedOut, verificationFailed
  case conflictingController, identityChanged, recoveryExhausted, priorRunUnresolved
  case protectionUnavailable, protectionLost, ownershipClearFailed, operationRefused
  case preferencesFailed, configurationChanged
}

public struct Policy: Codable, Equatable, Sendable {
  public var stableFor: Instant = 2000
  public var sampleSeparation: Instant = 500
  public var evidenceLifetime: Instant = 5000
  public var operationTimeout: Instant = 3000
  /// Saving the record shares the platform lane with display calls, which can stall for seconds
  /// while macOS reconfigures after a hotplug. A slow save is still in progress, not a failure,
  /// so past `operationTimeout` it is reported as slow, and past this as stalled.
  public var journalTimeout: Instant = 15000
  public var restoreRetryDelays: [Instant] = [500, 2000]
  public init() {}

  private enum CodingKeys: String, CodingKey {
    case stableFor, sampleSeparation, evidenceLifetime, operationTimeout, journalTimeout
    case restoreRetryDelays
  }

  /// Older replay exports predate `journalTimeout`, so it decodes with its default.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    stableFor = try values.decode(Instant.self, forKey: .stableFor)
    sampleSeparation = try values.decode(Instant.self, forKey: .sampleSeparation)
    evidenceLifetime = try values.decode(Instant.self, forKey: .evidenceLifetime)
    operationTimeout = try values.decode(Instant.self, forKey: .operationTimeout)
    journalTimeout = try values.decodeIfPresent(Instant.self, forKey: .journalTimeout) ?? 15000
    restoreRetryDelays = try values.decode([Instant].self, forKey: .restoreRetryDelays)
  }
}

public struct ControllerState: Codable, Equatable, Sendable {
  public var mode: Mode
  public var manualRequest = false
  public var observation: Observation?
  public var stableSince: Instant?
  public var matchingSamples = 0
  public var lastCountedSample: Instant?
  public var lastReceipt: Instant = 0
  public var operation: Operation?
  public var ownership: Ownership?
  public var fault: Fault?
  public var nextOperationID: UInt64 = 1
  public var restoreAttempts = 0
  public var retryAt: Instant?
  /// A pre-call deferral is not a failed display operation. Wait for a newer observation.
  public var recoveryDeferredSequence: UInt64?
  /// A lifecycle interruption must complete one verified restore before automatic intent can
  /// suppress the panel again. This survives the sleep interval without issuing a write in it.
  public var restorationRequired = false
  public var shuttingDown = false
  /// A paired recovery helper exists. Per-operation protection is still leased separately.
  public var protectionAvailable = false
  public var preferencesPending = false
  /// Restoration is verified but the durable record has not been cleared yet. Ownership is
  /// only released by a successful clear, never by a hopeful assumption that one happened.
  public var pendingClear = false
  public var policy: Policy

  public init(mode: Mode = .manual, recoveredOwnership: Ownership? = nil,
              policy: Policy = .init()) {
    self.mode = mode
    self.policy = policy
    ownership = recoveredOwnership
    if let recoveredOwnership {
      fault = .priorRunUnresolved
      nextOperationID = recoveredOwnership.operationID + 1
    }
  }

  private enum CodingKeys: String, CodingKey {
    case mode, manualRequest, observation, stableSince, matchingSamples, lastCountedSample
    case lastReceipt, operation, ownership, fault, nextOperationID, restoreAttempts, retryAt
    case recoveryDeferredSequence, restorationRequired, shuttingDown, protectionAvailable
    case preferencesPending, pendingClear, policy
  }

  /// Replay exports are durable diagnostics. New state fields therefore decode with their
  /// conservative defaults instead of making an older export unreadable.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    mode = try values.decode(Mode.self, forKey: .mode)
    manualRequest = try values.decodeIfPresent(Bool.self, forKey: .manualRequest) ?? false
    observation = try values.decodeIfPresent(Observation.self, forKey: .observation)
    stableSince = try values.decodeIfPresent(Instant.self, forKey: .stableSince)
    matchingSamples = try values.decodeIfPresent(Int.self, forKey: .matchingSamples) ?? 0
    lastCountedSample = try values.decodeIfPresent(Instant.self, forKey: .lastCountedSample)
    lastReceipt = try values.decodeIfPresent(Instant.self, forKey: .lastReceipt) ?? 0
    operation = try values.decodeIfPresent(Operation.self, forKey: .operation)
    ownership = try values.decodeIfPresent(Ownership.self, forKey: .ownership)
    fault = try values.decodeIfPresent(Fault.self, forKey: .fault)
    nextOperationID = try values.decodeIfPresent(UInt64.self, forKey: .nextOperationID) ?? 1
    restoreAttempts = try values.decodeIfPresent(Int.self, forKey: .restoreAttempts) ?? 0
    retryAt = try values.decodeIfPresent(Instant.self, forKey: .retryAt)
    recoveryDeferredSequence = try values.decodeIfPresent(
      UInt64.self, forKey: .recoveryDeferredSequence
    )
    restorationRequired = try values
      .decodeIfPresent(Bool.self, forKey: .restorationRequired) ?? false
    shuttingDown = try values.decodeIfPresent(Bool.self, forKey: .shuttingDown) ?? false
    protectionAvailable =
      try values.decodeIfPresent(Bool.self, forKey: .protectionAvailable) ?? false
    preferencesPending = try values.decodeIfPresent(Bool.self, forKey: .preferencesPending) ?? false
    pendingClear = try values.decodeIfPresent(Bool.self, forKey: .pendingClear) ?? false
    policy = try values.decodeIfPresent(Policy.self, forKey: .policy) ?? .init()
  }

  public var wantsOff: Bool {
    !shuttingDown && fault == nil && (mode == .automatic || (mode == .manual && manualRequest))
  }
}

public enum Event: Codable, Equatable, Sendable {
  case observed(Observation)
  case selectMode(Mode)
  case manualOff
  case keepOn
  case retry
  case tick
  case willSleep
  case waking
  case quit
  case journalSaved(operationID: UInt64, succeeded: Bool)
  case ownershipCleared(succeeded: Bool)
  case preferencesSaved(mode: Mode, succeeded: Bool)
  /// A paired helper appeared or went away. Losing it while owning a panel forces restoration.
  case protectionAvailable(Bool)
  /// The helper acknowledged a protection lease bound to this one operation.
  case protectionArmed(operationID: UInt64, succeeded: Bool)
  case operationReturned(operationID: UInt64, succeeded: Bool)
  case restoreDeferred(operationID: UInt64)
  /// The executor established, before issuing anything, that the request was no longer valid.
  /// Unlike a failed call this positively establishes that no display was touched.
  case operationRefused(operationID: UInt64)
}

public enum Effect: Codable, Equatable, Sendable {
  case observe
  case savePreferences(Mode)
  case saveOwnership(Ownership)
  case clearOwnership
  /// Ask the helper for a lease covering exactly this operation, before any display write.
  case armProtection(operationID: UInt64, ownership: Ownership)
  case releaseProtection
  /// The executor must perform its own final target and prerequisite check for disable.
  case setPanelEnabled(operationID: UInt64, target: PanelTarget, enabled: Bool)
  /// A timeout is not cancellation. The supervisor must stop the writer before taking over.
  case writerUnresponsive(operationID: UInt64)
  case wakeAt(Instant)
  case exitReady
}

public struct Transition: Codable, Equatable, Sendable {
  public var state: ControllerState
  public var effects: [Effect]
}

/// Why turning the internal display off is not currently possible. The interface must show a
/// specific reason rather than a bare unavailable state, so every blocker has a case here.
public enum Unavailability: String, Codable, CaseIterable, Equatable, Sendable {
  case noObservation, noConfirmedPanel, staleEvidence, lidClosed, notAwake
  /// No longer produced. Kept because replay exports are durable and older ones still decode.
  case backendUnvalidated
  case sessionNotForeground, noNativeExternal, unsupportedTopology
  case noRecoveryHelper, settling, unresolvedOwnership, faulted, shuttingDown
}

/// How long the safety record has been saving, once that is longer than it should take.
public enum JournalWait: Equatable, Sendable {
  case slow, stalled
}

/// A read-only projection for the menu. It derives from state and carries no new authority.
public struct Presentation: Equatable, Sendable {
  public var mode: Mode
  public var manualRequestActive: Bool
  public var panelOwned: Bool
  public var operationInFlight: Bool
  public var pendingRecovery: Bool
  public var fault: Fault?
  public var unavailability: Unavailability?
  public var waitingForRecovery = false
  /// What the person asked for, which is not the same as what is on screen right now.
  /// External Only stays chosen while the monitor is unplugged and the panel is lit.
  public var wantsInternalOff = false
  public var journalWait: JournalWait?

  public init(
    mode: Mode, manualRequestActive: Bool, panelOwned: Bool, operationInFlight: Bool,
    pendingRecovery: Bool, fault: Fault?, unavailability: Unavailability?
  ) {
    self.mode = mode
    self.manualRequestActive = manualRequestActive
    self.panelOwned = panelOwned
    self.operationInFlight = operationInFlight
    self.pendingRecovery = pendingRecovery
    self.fault = fault
    self.unavailability = unavailability
  }

  public var canDisableNow: Bool {
    unavailability == nil
  }
}

public extension Controller {
  /// The first blocking reason, in the order the controller itself checks them.
  static func unavailability(_ state: ControllerState, at now: Instant) -> Unavailability? {
    if state.shuttingDown {
      return .shuttingDown
    }
    if state.fault != nil {
      return .faulted
    }
    if state.pendingClear {
      return .unresolvedOwnership
    }
    guard let sample = state.observation else { return .noObservation }
    if now < sample.sampledAt || now - sample.sampledAt > state.policy.evidenceLifetime {
      return .staleEvidence
    }
    let environment = sample.environment
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
    if !state.protectionAvailable {
      return .noRecoveryHelper
    }
    if state.ownership != nil {
      return nil
    }
    guard state.matchingSamples >= 2, let since = state.stableSince,
          now - since >= state.policy.stableFor
    else { return .settling }
    return nil
  }

  static func presentation(_ state: ControllerState, at now: Instant) -> Presentation {
    var result = Presentation(
      mode: state.mode, manualRequestActive: state.manualRequest,
      panelOwned: state.ownership != nil, operationInFlight: state.operation != nil,
      pendingRecovery: state.ownership != nil || state.pendingClear, fault: state.fault,
      unavailability: unavailability(state, at: now)
    )
    result.waitingForRecovery =
      state.ownership != nil && !state.pendingClear
        && (state.recoveryDeferredSequence != nil
          || state.observation?.environment.visibilityExpected != true)
    result.wantsInternalOff = state.wantsOff
    if let op = state.operation, op.phase == .journaling, let started = op.startedAt {
      let elapsed = now - started
      if elapsed >= state.policy.journalTimeout {
        result.journalWait = .stalled
      } else if elapsed >= state.policy.operationTimeout {
        result.journalWait = .slow
      }
    }
    return result
  }
}
