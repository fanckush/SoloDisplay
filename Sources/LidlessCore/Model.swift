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
  public var prerequisitesMet: Bool {
    panel != nil && power == .awake && lid == .open && foregroundSession == .yes
      && nativeExternalAvailable == .yes && supportedTopology == .yes && backendValidated == .yes
  }

  var visibilityExpected: Bool { power == .awake && lid == .open && foregroundSession == .yes }
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
}

public struct Ownership: Codable, Equatable, Sendable {
  public var target: PanelTarget
  public var operationID: UInt64

  public init(target: PanelTarget, operationID: UInt64) {
    self.target = target
    self.operationID = operationID
  }
}

public enum Fault: String, Codable, Sendable {
  case journalFailed, operationFailed, operationTimedOut, verificationFailed
  case conflictingController, identityChanged, recoveryExhausted, priorRunUnresolved
  case protectionUnavailable, protectionLost, ownershipClearFailed, operationRefused
}

public struct Policy: Codable, Equatable, Sendable {
  public var stableFor: Instant = 2_000
  public var sampleSeparation: Instant = 500
  public var evidenceLifetime: Instant = 5_000
  public var operationTimeout: Instant = 3_000
  public var restoreRetryDelays: [Instant] = [500, 2_000]
  public init() {}
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
  public var shuttingDown = false
  /// A paired recovery helper exists. Per-operation protection is still leased separately.
  public var protectionAvailable = false
  /// Restoration is verified but the durable record has not been cleared yet. Ownership is
  /// only released by a successful clear, never by a hopeful assumption that one happened.
  public var pendingClear = false
  public var policy: Policy

  public init(mode: Mode = .manual, recoveredOwnership: Ownership? = nil, policy: Policy = .init())
  {
    self.mode = mode
    self.policy = policy
    ownership = recoveredOwnership
    if let recoveredOwnership {
      fault = .priorRunUnresolved
      nextOperationID = recoveredOwnership.operationID + 1
    }
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
  /// A paired helper appeared or went away. Losing it while owning a panel forces restoration.
  case protectionAvailable(Bool)
  /// The helper acknowledged a protection lease bound to this one operation.
  case protectionArmed(operationID: UInt64, succeeded: Bool)
  case operationReturned(operationID: UInt64, succeeded: Bool)
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
public enum Unavailability: String, Codable, Equatable, Sendable {
  case noObservation, noConfirmedPanel, staleEvidence, lidClosed, notAwake
  case sessionNotForeground, noNativeExternal, unsupportedTopology, backendUnvalidated
  case noRecoveryHelper, settling, unresolvedOwnership, faulted, shuttingDown
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

  public var canDisableNow: Bool { unavailability == nil }
}

extension Controller {
  /// The first blocking reason, in the order the controller itself checks them.
  public static func unavailability(_ state: ControllerState, at now: Instant) -> Unavailability? {
    if state.shuttingDown { return .shuttingDown }
    if state.fault != nil { return .faulted }
    if state.pendingClear { return .unresolvedOwnership }
    guard let sample = state.observation else { return .noObservation }
    if now < sample.sampledAt || now - sample.sampledAt > state.policy.evidenceLifetime {
      return .staleEvidence
    }
    let environment = sample.environment
    if environment.panel == nil { return .noConfirmedPanel }
    if environment.lid != .open { return .lidClosed }
    if environment.power != .awake { return .notAwake }
    if environment.foregroundSession != .yes { return .sessionNotForeground }
    if environment.backendValidated != .yes { return .backendUnvalidated }
    if environment.supportedTopology != .yes { return .unsupportedTopology }
    if environment.nativeExternalAvailable != .yes { return .noNativeExternal }
    if !state.protectionAvailable { return .noRecoveryHelper }
    if state.ownership != nil { return nil }
    guard state.matchingSamples >= 2, let since = state.stableSince,
      now - since >= state.policy.stableFor
    else { return .settling }
    return nil
  }

  public static func presentation(_ state: ControllerState, at now: Instant) -> Presentation {
    .init(
      mode: state.mode, manualRequestActive: state.manualRequest,
      panelOwned: state.ownership != nil, operationInFlight: state.operation != nil,
      pendingRecovery: state.ownership != nil || state.pendingClear, fault: state.fault,
      unavailability: unavailability(state, at: now))
  }
}
