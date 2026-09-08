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

  var prerequisitesMet: Bool {
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
public enum OperationPhase: String, Codable, Sendable {
  case journaling, submitted, verifying, stalled
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
  case operationReturned(operationID: UInt64, succeeded: Bool)
}

public enum Effect: Codable, Equatable, Sendable {
  case observe
  case savePreferences(Mode)
  case saveOwnership(Ownership)
  case clearOwnership
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
