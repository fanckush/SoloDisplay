/// Time supplied by the executor, in monotonic milliseconds. No wall clock in the core.
public typealias Instant = Int64

public enum Mode: String, Codable, Sendable { case manual, automatic, automaticPaused }
public enum Fact: String, Codable, Sendable { case yes, no, unknown, conflicting }
public enum Power: String, Codable, Sendable { case awake, sleeping, waking, unknown }
public enum Lid: String, Codable, Sendable { case open, closed, absent, unknown }
public enum PanelState: String, Codable, Sendable { case enabled, disabled, unknown }

/// What one monitor is showing. `unknown` is the default and is never read as a quiet yes: a
/// monitor that cannot answer, or answers something this Mac cannot interpret, says nothing.
public enum ShownSource: String, Codable, Equatable, Sendable {
  case thisMac, otherMachine, unknown
}

/// One monitor's answer, with the monitor it belongs to when that is known.
public struct MonitorAnswer: Codable, Equatable, Sendable {
  public var controller: String
  public var target: PanelTarget?
  public var shown: ShownSource

  public init(controller: String, target: PanelTarget?, shown: ShownSource) {
    self.controller = controller
    self.target = target
    self.shown = shown
  }
}

/// Which screen a target names. The laptop panel is always there to be looked up again; an
/// external is not, so the two are recovered from different evidence.
public enum TargetKind: String, Codable, Sendable { case builtIn, external }

/// Valid only within the recorded boot and GUI login session. UUID alone is not authority.
public struct PanelTarget: Codable, Equatable, Sendable {
  public var displayID: UInt32
  public var displayUUID: String
  public var bootID: String
  public var loginID: UInt32
  public var kind: TargetKind
  /// The DDC endpoint, such as `dispext0`, for an external. It is how a monitor that has been
  /// turned off is still found: the endpoint outlives the display, which leaves CoreGraphics
  /// entirely. It is a port, not a monitor, so it never stands alone as identity.
  public var controller: String?

  public init(
    displayID: UInt32, displayUUID: String, bootID: String, loginID: UInt32,
    kind: TargetKind = .builtIn, controller: String? = nil
  ) {
    self.displayID = displayID
    self.displayUUID = displayUUID
    self.bootID = bootID
    self.loginID = loginID
    self.kind = kind
    self.controller = controller
  }

  private enum CodingKeys: String, CodingKey {
    case displayID, displayUUID, bootID, loginID, kind, controller
  }

  /// A record written before externals could be named holds a built-in panel and nothing else.
  /// Failing to read it would inhibit turning anything off, so the older shape is read, not
  /// rejected.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    displayID = try container.decode(UInt32.self, forKey: .displayID)
    displayUUID = try container.decode(String.self, forKey: .displayUUID)
    bootID = try container.decode(String.self, forKey: .bootID)
    loginID = try container.decode(UInt32.self, forKey: .loginID)
    kind = try container.decodeIfPresent(TargetKind.self, forKey: .kind) ?? .builtIn
    controller = try container.decodeIfPresent(String.self, forKey: .controller)
  }
}

/// One monitor, as the controller sees it.
public struct ExternalCandidate: Codable, Equatable, Sendable {
  public var target: PanelTarget
  /// It could be turned off right now: live, native, and nothing else follows it.
  public var suppressible: Bool
  /// SoloDisplay turned it off, so it is not in the display inventory at all.
  public var suppressed: Bool

  public init(target: PanelTarget, suppressible: Bool, suppressed: Bool) {
    self.target = target
    self.suppressible = suppressible
    self.suppressed = suppressed
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
  /// Every monitor with a DDC endpoint, live or turned off by this app.
  public var externals: [ExternalCandidate]
  /// Screens a person could look at right now. The laptop panel counts only while it is on.
  public var visibleDisplays: Int

  public init(
    panel: PanelTarget?, panelState: PanelState, power: Power, lid: Lid,
    foregroundSession: Fact, nativeExternalAvailable: Fact, supportedTopology: Fact,
    externals: [ExternalCandidate] = [], visibleDisplays: Int = 0
  ) {
    self.panel = panel
    self.panelState = panelState
    self.power = power
    self.lid = lid
    self.foregroundSession = foregroundSession
    self.nativeExternalAvailable = nativeExternalAvailable
    self.supportedTopology = supportedTopology
    self.externals = externals
    self.visibleDisplays = visibleDisplays
  }

  /// A record written before monitors were described reads without them.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    panel = try container.decodeIfPresent(PanelTarget.self, forKey: .panel)
    panelState = try container.decode(PanelState.self, forKey: .panelState)
    power = try container.decode(Power.self, forKey: .power)
    lid = try container.decode(Lid.self, forKey: .lid)
    foregroundSession = try container.decode(Fact.self, forKey: .foregroundSession)
    nativeExternalAvailable = try container.decode(Fact.self, forKey: .nativeExternalAvailable)
    supportedTopology = try container.decode(Fact.self, forKey: .supportedTopology)
    externals = try container.decodeIfPresent([ExternalCandidate].self, forKey: .externals) ?? []
    visibleDisplays = try container.decodeIfPresent(Int.self, forKey: .visibleDisplays) ?? 0
  }

  /// Changes produced by our own panel change do not restart settling.
  func hasSamePrerequisites(as other: Environment) -> Bool {
    panel == other.panel && power == other.power && lid == other.lid
      && foregroundSession == other.foregroundSession
      && nativeExternalAvailable == other.nativeExternalAvailable
      && supportedTopology == other.supportedTopology
      && externals.map(\.target) == other.externals.map(\.target)
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
  /// How often the monitors are asked what they are showing.
  public var inputSourceInterval: Instant = 10000
  /// An answer that would change something is confirmed sooner than the ordinary interval.
  public var inputSourceConfirm: Instant = 1000
  /// Answers in a row that must agree before the answer itself changes.
  public var inputSourceReadings = 2
  /// An ask that never comes back stops holding the decision open after this.
  public var inputSourceDeadline: Instant = 5000
  /// A monitor is left alone for this long after it was last turned off or back on, so a fight
  /// between two rules shows up as slowness rather than as a flashing screen.
  public var monitorSettleFloor: Instant = 30000
  /// Attempts at one monitor that do not land before it is given up on.
  public var monitorAttempts = 2
  /// A monitor that has answered nothing for this long is turned back on. A monitor usually
  /// answers again once it is switched back, so this is a backstop, not the way back.
  public var monitorSilence: Instant = 300_000
  public init() {}
}

public enum WriteAction: String, Codable, Sendable { case disable, enable }

/// How a worker process ended. None of these says what the display did.
public enum WorkerOutcome: String, Codable, Sendable { case done, refused, failed, killed }

public enum GuardianState: String, Codable, Sendable { case absent, starting, ready }

/// One monitor's standing answer, and the answer that is trying to replace it. Acting on a
/// monitor needs the same answer twice, because turning a screen off is a change.
public struct MonitorVerdict: Equatable, Sendable {
  public var shown: ShownSource = .unknown
  public var pending: ShownSource = .unknown
  public var agreeing = 0
  public var lastAnswered: Instant = 0
  /// When this monitor was last turned off or back on by this app.
  public var lastChanged: Instant?

  public init() {}
}

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
  /// The monitors this run has turned off. They are not in any display inventory, so this is the
  /// only thing that says they exist and whose doing it was.
  public var suppressed: [PanelTarget] = []
  /// A write of that set is running.
  public var suppressedBusy = false
  /// What the record on disk names, so the two can be brought back together.
  public var recordedSuppression: [PanelTarget] = []
  /// Attempts at each monitor that did not land, by display UUID. A monitor that cannot be
  /// changed is given up on rather than tried for ever: it is usually one that was unplugged.
  public var monitorAttempts: [String: Int] = [:]
  /// Everything the guardian has been told is owed, so it is told again only when it changes.
  /// A guardian that does not know about something cannot give it back.
  public var guardianTargets: [PanelTarget] = []
  /// What each monitor is showing, keyed by DDC endpoint.
  public var monitors: [String: MonitorVerdict] = [:]
  /// What the monitors say they are showing. A veto and nothing else: `.no` refuses to turn the
  /// laptop screen off and asks for it back, `.yes` only lifts that refusal, and `.unknown` does
  /// nothing in either direction. A monitor with no DDC leaves it `.unknown` for ever.
  public var inputSources: Fact = .unknown
  /// An answer that has not repeated yet. Enough to refuse, not enough to act.
  public var inputSourcesPending: Fact = .unknown
  public var inputSourcesAgreeing = 0
  /// When the monitors were last asked, whatever they said, and whether an ask is still out.
  public var inputSourcesAskedAt: Instant?
  public var inputSourcesBusy = false
  public var inputSourcesDueAt: Instant?
  public var policy: Policy

  public init(mode: Mode = .automaticPaused, record: PanelTarget? = nil, policy: Policy = .init()) {
    self.mode = mode
    self.record = record
    self.policy = policy
  }

  public var wantsOff: Bool {
    mode == .automatic
  }

  /// Everything this run has turned off: the laptop panel when it is off, and every monitor.
  /// This is what a guardian is given, and nothing may be off that is not in it.
  public var ownedTargets: [PanelTarget] {
    [record].compactMap(\.self) + suppressed
  }

  /// A monitor said, even once, that it is showing another machine. Withholding costs nothing and
  /// the next answer undoes it, so one answer is enough.
  var inputRefusal: Bool {
    inputSources == .no || inputSourcesPending == .no
  }

  /// The same answer twice. Putting the laptop screen back is a change, so it waits for that.
  var inputDemand: Bool {
    inputSources == .no
  }

  /// A changed arrangement has to be asked again before anything is turned off, but what the
  /// monitors last said is kept. Putting the laptop screen back is itself a reconfiguration, so
  /// dropping the refusal here would turn the screen off, on, off, on for ever.
  mutating func remeasureInputSources() {
    inputSourcesAskedAt = nil
    inputSourcesDueAt = nil
  }

  /// Nothing the monitors say can change anything once the answer is no longer wanted.
  mutating func forgetInputSources() {
    inputSources = .unknown
    inputSourcesPending = .unknown
    inputSourcesAgreeing = 0
    inputSourcesAskedAt = nil
    inputSourcesDueAt = nil
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
  /// What the monitors said they are showing, and when they were asked. `.unknown` is an answer
  /// that says nothing, which is what a monitor without DDC always gives.
  /// `monitors` is nil when no sweep answered at all, such as one given up on. That is not the
  /// same as a sweep that found no monitors, which is an empty list and means they have gone.
  case inputSourcesRead(Fact, monitors: [MonitorAnswer]? = nil, sampledAt: Instant)
  /// The set of monitors this run has turned off was written, or could not be.
  case suppressionRecorded([PanelTarget], succeeded: Bool)
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
  case spawnGuardian([PanelTarget])
  case releaseGuardian
  case runWorker(WriteAction, PanelTarget)
  /// Ask the monitors what they are showing. Slow, so it has its own lane and its own answer.
  case readInputSources
  /// Record the monitors this run has turned off, before any of them is turned off.
  case recordSuppression([PanelTarget])
  /// Tell a running guardian the whole set of monitors owed now.
  case updateGuardian([PanelTarget])
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
  case noNativeExternal, unsupportedTopology, monitorShowsAnotherMachine, settling, notRunning
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
  /// Monitors SoloDisplay has turned off because they are showing another machine.
  public var suppressedMonitors = 0

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
