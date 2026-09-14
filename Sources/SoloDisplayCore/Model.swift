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

  public init(
    panel: PanelTarget?, panelState: PanelState, power: Power, lid: Lid,
    foregroundSession: Fact, nativeExternalAvailable: Fact, supportedTopology: Fact
  ) {
    self.panel = panel
    self.panelState = panelState
    self.power = power
    self.lid = lid
    self.foregroundSession = foregroundSession
    self.nativeExternalAvailable = nativeExternalAvailable
    self.supportedTopology = supportedTopology
  }

  /// Changes produced by our own panel change do not restart settling.
  func hasSamePrerequisites(as other: Environment) -> Bool {
    panel == other.panel && power == other.power && lid == other.lid
      && foregroundSession == other.foregroundSession
      && nativeExternalAvailable == other.nativeExternalAvailable
      && supportedTopology == other.supportedTopology
  }

  /// Everything that has to hold for the laptop screen to be off.
  public var prerequisitesMet: Bool {
    panel != nil && power == .awake && lid == .open && foregroundSession == .yes
      && nativeExternalAvailable == .yes && supportedTopology == .yes
  }

  /// A change can only be made, and seen, on an awake Mac with the lid open in front of its user.
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

public struct Policy: Equatable, Sendable {
  public var stableFor: Instant = 2000
  public var sampleSeparation: Instant = 500
  /// After macOS reports a display reconfiguration, this long without another one means it is
  /// done. It replaces `stableFor` only when such a report explains the current arrangement.
  public var quietFor: Instant = 500
  /// Reconfiguration reports that never go quiet stop holding the decision back after this.
  public var settleCap: Instant = 5000
  /// Waits after an attempt that did not reach the wanted state. The last one repeats.
  public var retryDelays: [Instant] = [500, 1000, 2000, 5000, 10000, 30000]
  /// Attempts that miss in a row before the menu says so. Attempts continue either way.
  public var troubleAfter = 3
  public init() {}
}

public enum WriteAction: String, Codable, Sendable { case disable, enable }

/// How a worker process ended. None of these says what the display did.
public enum WorkerOutcome: String, Codable, Sendable { case done, refused, failed, killed }

public enum GuardianState: String, Codable, Sendable { case absent, starting, ready }

public struct RunningWorker: Equatable, Sendable {
  public var action: WriteAction
  public var target: PanelTarget
  public var startedAt: Instant
  public var finishedAt: Instant?
  public var outcome: WorkerOutcome?
}

public struct ControllerState: Equatable, Sendable {
  public var mode: Mode
  public var observation: Observation?
  public var stableSince: Instant?
  public var matchingSamples = 0
  public var lastCountedSample: Instant?
  public var lastReceipt: Instant = 0
  /// When macOS last reported a display reconfiguration, and whether that report opened one
  /// that has not finished yet. Evidence for settling only, never for writing.
  public var lastDisplayChange: Instant?
  public var displayConfiguring = false
  /// The panel the record on disk names. Its absence reads as SoloDisplay's own suppression.
  public var record: PanelTarget?
  /// A record write, clear, or reconciliation is running.
  public var recordBusy = false
  public var recordFailed = false
  /// A leftover record names nothing this session can identify. Nothing is turned off meanwhile.
  public var recordBlocked = false
  public var preferencesFailed = false
  public var guardian: GuardianState = .absent
  public var worker: RunningWorker?
  /// Attempts in a row that did not reach the wanted state. Cleared as soon as one does.
  public var failures = 0
  public var retryAt: Instant?
  public var policy: Policy

  public init(mode: Mode = .automaticPaused, record: PanelTarget? = nil, policy: Policy = .init()) {
    self.mode = mode
    self.record = record
    self.policy = policy
  }

  public var wantsOff: Bool {
    mode == .automatic
  }
}

public enum Event: Equatable, Sendable {
  case observed(Observation)
  /// macOS reported a display reconfiguration. `inProgress` means the last report opened one.
  case displayReconfigured(inProgress: Bool)
  case selectMode(Mode)
  case preferencesSaved(succeeded: Bool)
  case willSleep
  case waking
  /// Try Again: forget the backoff and look again now.
  case retry
  case tick
  case recordWritten(PanelTarget, succeeded: Bool)
  case recordCleared(succeeded: Bool)
  case recordReconciled(PanelTarget?, blocked: Bool)
  case guardianReady
  case guardianGone
  case workerFinished(WorkerOutcome)
}

public enum Effect: Equatable, Sendable {
  case observe
  /// Take a reading at this instant, because it is when settling could first complete.
  case observeAt(Instant)
  case wakeAt(Instant)
  case savePreferences(Mode)
  case writeRecord(PanelTarget)
  case clearRecord
  case reconcileRecord
  case spawnGuardian(PanelTarget)
  case releaseGuardian
  case runWorker(WriteAction, PanelTarget)
}

public struct Transition: Equatable, Sendable {
  public var state: ControllerState
  public var effects: [Effect]
}

/// Something is not working and has lasted. Every case clears itself once it stops being true.
public enum Trouble: String, Codable, CaseIterable, Sendable {
  case stillTrying, recordNotSaved, recordUnresolved, preferencesNotSaved
}

/// Why the laptop screen cannot be off right now.
public enum Unavailability: String, Codable, CaseIterable, Equatable, Sendable {
  case noObservation, noConfirmedPanel, lidClosed, notAwake, sessionNotForeground
  case noNativeExternal, unsupportedTopology, settling, notRunning
}

/// A read-only projection for the menu. It derives from state and carries no new authority.
public struct Presentation: Equatable, Sendable {
  /// What the person asked for, which is not the same as what is on screen right now.
  public var wantsInternalOff: Bool
  public var panelOff: Bool
  /// A change toward what was asked for is under way.
  public var working: Bool
  public var trouble: Trouble?
  public var unavailability: Unavailability?

  public init(
    wantsInternalOff: Bool = false, panelOff: Bool = false, working: Bool = false,
    trouble: Trouble? = nil, unavailability: Unavailability? = nil
  ) {
    self.wantsInternalOff = wantsInternalOff
    self.panelOff = panelOff
    self.working = working
    self.trouble = trouble
    self.unavailability = unavailability
  }

  public var canDisableNow: Bool {
    unavailability == nil
  }
}
