import Foundation
import SoloDisplayCore

public protocol CoordinatorClock: Sendable {
  /// Monotonic milliseconds. A wall clock must never reach the reducer.
  func now() -> Instant
}

public protocol PlatformObserving: Sendable {
  func read() -> PlatformReading
}

public protocol DisplayWriting: Sendable {
  /// Makes one change with session scope and reports how the attempt ended. The outcome never
  /// says what the display did; only a later reading does.
  func setEnabled(_ enabled: Bool, target: PanelTarget) -> WorkerOutcome
}

public protocol OwnershipPersisting: Sendable {
  func prepare(_ record: ProductionRecord) throws
  func clear() throws
  func reconcile(bootID: String?, loginID: UInt32?, displays: [DisplayReading])
    -> JournalReconciliation
}

public protocol PreferencePersisting: Sendable {
  func save(mode: Mode) throws
}

/// Starts the guardian child and reports on it. Callbacks arrive on the main actor.
@MainActor public protocol GuardianControlling: AnyObject {
  func spawn(
    target: PanelTarget, ready: @escaping @MainActor () -> Void,
    gone: @escaping @MainActor () -> Void
  )
  /// Tells the guardian nothing is owed, so it exits without touching the display.
  func release()
}

/// A serial execution lane for synchronous work. Results always come back, even late.
public protocol SerialLane: Sendable {
  func run(
    _ work: @escaping @Sendable () -> Event,
    completion: @escaping @Sendable @MainActor (Event) -> Void
  )
  func observe(
    _ work: @escaping @Sendable () -> PlatformReading,
    completion: @escaping @Sendable @MainActor (PlatformReading) -> Void
  )
}

@MainActor public protocol CoordinatorScheduler: AnyObject {
  func after(_ seconds: Double, _ fire: @escaping @MainActor () -> Void)
  func startRepeating(_ seconds: Double, _ fire: @escaping @MainActor () -> Void)
  func stopRepeating()
}

/// One background queue per lane, results delivered on the main actor.
public struct DispatchLane: SerialLane {
  private let queue: DispatchQueue
  public init(label: String = "dev.solodisplay.lane") {
    queue = DispatchQueue(label: label, qos: .userInitiated)
  }

  public func run(
    _ work: @escaping @Sendable () -> Event,
    completion: @escaping @Sendable @MainActor (Event) -> Void
  ) {
    queue.async {
      let event = work()
      Task { @MainActor in completion(event) }
    }
  }

  public func observe(
    _ work: @escaping @Sendable () -> PlatformReading,
    completion: @escaping @Sendable @MainActor (PlatformReading) -> Void
  ) {
    queue.async {
      let reading = work()
      Task { @MainActor in completion(reading) }
    }
  }
}

@MainActor
public final class TimerScheduler: CoordinatorScheduler {
  private var repeating: Timer?
  public init() {}
  /// Common mode, so a modal loop such as menu tracking cannot silently stop the controller.
  public func after(_ seconds: Double, _ fire: @escaping @MainActor () -> Void) {
    let timer = Timer(timeInterval: max(seconds, 0), repeats: false) { _ in
      MainActor.assumeIsolated { fire() }
    }
    RunLoop.main.add(timer, forMode: .common)
  }

  public func startRepeating(_ seconds: Double, _ fire: @escaping @MainActor () -> Void) {
    repeating?.invalidate()
    let timer = Timer(timeInterval: seconds, repeats: true) { _ in
      MainActor.assumeIsolated { fire() }
    }
    RunLoop.main.add(timer, forMode: .common)
    repeating = timer
  }

  public func stopRepeating() {
    repeating?.invalidate()
    repeating = nil
  }
}

@MainActor public protocol CoordinatorDelegate: AnyObject {
  func coordinator(_ coordinator: ProductionCoordinator, didUpdate presentation: Presentation)
}

/// Runs the pure controller against the real platform. Decisions happen here, on the main actor,
/// one event at a time. Readings, storage and display workers each run on their own lane, so a
/// slow one of them delays only itself and never blocks a decision.
@MainActor
public final class ProductionCoordinator {
  public private(set) var state: ControllerState
  public var presentation: Presentation {
    Controller.presentation(state, at: clock.now())
  }

  private let clock: any CoordinatorClock
  private let diagnostics: OperationalLogger
  private let observer: any PlatformObserving
  private let writer: any DisplayWriting
  private let ownership: any OwnershipPersisting
  private let preferences: any PreferencePersisting
  private let guardian: (any GuardianControlling)?
  private weak var delegate: (any CoordinatorDelegate)?
  private let lane: any SerialLane
  private let storageLane: any SerialLane
  private let workerLane: any SerialLane
  private let scheduler: any CoordinatorScheduler
  private let session: String

  private var observationSequence: UInt64 = 0
  private var observationInFlight = false
  /// Something asked for a reading while one was under way. That reading was sampled too early
  /// to answer it, so another follows.
  private var observeAgain = false
  private var scheduledObservations: Set<Instant> = []
  private var lifecycle: Power = .unknown
  private var lastDiagnosticEnvironment: OperationalEnvironment?
  /// The newest raw reading, so a record can carry the arrangement it was written against.
  private var lastReading: PlatformReading?
  /// Bumped on every spawn and release, so a late callback from an earlier guardian is ignored.
  private var guardianGeneration: UInt64 = 0

  public init(
    state: ControllerState, clock: any CoordinatorClock, observer: any PlatformObserving,
    writer: any DisplayWriting, ownership: any OwnershipPersisting,
    preferences: any PreferencePersisting, guardian: (any GuardianControlling)?,
    delegate: (any CoordinatorDelegate)?, lane: any SerialLane = DispatchLane(),
    storageLane: any SerialLane = DispatchLane(label: "dev.solodisplay.storage"),
    workerLane: any SerialLane = DispatchLane(label: "dev.solodisplay.worker"),
    scheduler: (any CoordinatorScheduler)? = nil, session: String = UUID().uuidString,
    diagnostics: OperationalLogger = .init(role: .app)
  ) {
    self.state = state
    self.clock = clock
    self.observer = observer
    self.writer = writer
    self.ownership = ownership
    self.preferences = preferences
    self.guardian = guardian
    self.delegate = delegate
    self.lane = lane
    self.storageLane = storageLane
    self.workerLane = workerLane
    self.scheduler = scheduler ?? TimerScheduler()
    self.session = session
    self.diagnostics = diagnostics
  }

  public func start() {
    lifecycle = .awake
    observe()
    // Refresh at least every two seconds, and give retries and settling a regular look.
    scheduler.startRepeating(0.5) { [weak self] in self?.tick() }
  }

  public func stop() {
    scheduler.stopRepeating()
  }

  /// A display callback or workspace notification only ever schedules a reading.
  public func platformDidChange() {
    observe()
  }

  /// What a leftover record means at launch. A record that names nothing in this session is
  /// harmless once the built-in panel is visibly on, so it is cleared; otherwise disabling
  /// waits until the person can make the panel identifiable again.
  public nonisolated static func resolveRecord(
    _ store: any OwnershipPersisting, reading: PlatformReading?
  ) -> (target: PanelTarget?, blocked: Bool) {
    guard let reading else { return (nil, true) }
    switch store.reconcile(
      bootID: reading.bootID, loginID: reading.loginID, displays: reading.displays
    ) {
    case .clean:
      return (nil, false)
    case let .unresolved(record):
      return (record.target, false)
    case .priorSession, .retained:
      let panelOn = reading.displays.contains {
        $0.builtIn && $0.online && ($0.active || $0.mirrorSourceID != nil)
      }
      guard panelOn, (try? store.clear()) != nil else { return (nil, true) }
      return (nil, false)
    }
  }

  // MARK: - Events

  public func send(_ event: Event) {
    let now = clock.now()
    recordDiagnostics(for: event)
    switch event {
    case .willSleep:
      lifecycle = .sleeping
    case .waking:
      lifecycle = .waking
    case let .observed(sample) where sample.environment.power != lifecycle:
      diagnostics.emit(.lifecycleReconciled, session: session, reason: .observationFallback)
      lifecycle = sample.environment.power
    default:
      break
    }
    let transition = Controller.reduce(state, event, at: now)
    state = transition.state
    for effect in transition.effects {
      execute(effect, at: now)
    }
    delegate?.coordinator(self, didUpdate: Controller.presentation(state, at: now))
  }

  private func tick() {
    if let sample = state.observation, clock.now() - sample.sampledAt >= 2000 {
      observe()
    }
    send(.tick)
  }

  private func recordDiagnostics(for event: Event) {
    switch event {
    case let .observed(observation):
      let summary = OperationalEnvironment(observation.environment)
      if summary != lastDiagnosticEnvironment {
        lastDiagnosticEnvironment = summary
        diagnostics.emit(.environmentChanged, session: session) { $0.environment = summary }
      }
    case let .recordWritten(_, succeeded):
      diagnostics.emit(.journalPrepared, session: session, succeeded: succeeded)
    case let .recordCleared(succeeded):
      diagnostics.emit(.journalCleared, session: session, succeeded: succeeded)
    case let .preferencesSaved(succeeded):
      diagnostics.emit(.preferencesSaved, session: session, succeeded: succeeded)
    case .guardianReady:
      diagnostics.emit(.guardianReady, session: session)
    case .guardianGone:
      diagnostics.emit(.guardianGone, session: session)
    case let .workerFinished(outcome):
      let worker = state.worker
      diagnostics.emit(.workerFinished, session: session, succeeded: outcome == .done) {
        $0.workerAction = worker?.action
        $0.workerOutcome = outcome
        $0.elapsedMS = worker.map { max(0, self.clock.now() - $0.startedAt) }
      }
    default:
      break
    }
  }

  // MARK: - Effects

  private func execute(_ effect: Effect, at now: Instant) {
    switch effect {
    case .observe:
      observe()
    case let .observeAt(instant):
      scheduleObservation(at: instant, from: now)
    case let .wakeAt(instant):
      scheduler.after(Double(max(instant - now, 0)) / 1000) { [weak self] in self?.send(.tick) }
    case let .savePreferences(mode):
      let preferences = preferences
      storageLane.run {
        do {
          try preferences.save(mode: mode)
          return .preferencesSaved(succeeded: true)
        } catch { return .preferencesSaved(succeeded: false) }
      } completion: { [weak self] in self?.send($0) }
    case let .writeRecord(target):
      writeRecord(target)
    case .clearRecord:
      let ownership = ownership
      diagnostics.emit(.journalClearing, session: session)
      storageLane.run {
        do {
          try ownership.clear()
          return .recordCleared(succeeded: true)
        } catch { return .recordCleared(succeeded: false) }
      } completion: { [weak self] in self?.send($0) }
    case .reconcileRecord:
      let ownership = ownership
      let reading = lastReading
      storageLane.run {
        let resolved = Self.resolveRecord(ownership, reading: reading)
        return .recordReconciled(resolved.target, blocked: resolved.blocked)
      } completion: { [weak self] in self?.send($0) }
    case let .spawnGuardian(target):
      spawnGuardian(target)
    case .releaseGuardian:
      guardianGeneration &+= 1
      diagnostics.emit(.guardianReleased, session: session)
      guardian?.release()
    case let .runWorker(action, target):
      let writer = writer
      diagnostics.emit(.workerStarted, session: session) { $0.workerAction = action }
      workerLane.run {
        .workerFinished(writer.setEnabled(action == .enable, target: target))
      } completion: { [weak self] in self?.send($0) }
    }
  }

  private func writeRecord(_ target: PanelTarget) {
    let record = ProductionRecord(
      session: session, operationID: 1, target: target, scope: "session",
      controllerPID: ProcessInfo.processInfo.processIdentifier, helperPID: 0,
      topology: lastReading?.displays ?? []
    )
    let ownership = ownership
    diagnostics.emit(.journalPreparing, session: session)
    storageLane.run {
      do {
        try ownership.prepare(record)
        return .recordWritten(target, succeeded: true)
      } catch {
        return .recordWritten(target, succeeded: false)
      }
    } completion: { [weak self] in self?.send($0) }
  }

  private func spawnGuardian(_ target: PanelTarget) {
    guardianGeneration &+= 1
    let generation = guardianGeneration
    diagnostics.emit(.guardianStarted, session: session)
    guard let guardian else {
      send(.guardianGone)
      return
    }
    guardian.spawn(
      target: target,
      ready: { [weak self] in
        guard let self, guardianGeneration == generation else { return }
        send(.guardianReady)
      },
      gone: { [weak self] in
        guard let self, guardianGeneration == generation else { return }
        send(.guardianGone)
      }
    )
  }

  // MARK: - Observation

  private func observe() {
    guard !observationInFlight else {
      observeAgain = true
      return
    }
    observationInFlight = true
    observationSequence += 1
    let sequence = observationSequence
    let observer = observer
    // Sampling time is taken before the read, so evidence is never treated as fresher than it is.
    let sampledAt = clock.now()
    lane.observe {
      observer.read()
    } completion: { [weak self] reading in
      guard let self else { return }
      observationInFlight = false
      lastReading = reading
      // The record, read now rather than at dispatch, is what makes an absent panel readable as
      // SoloDisplay's own suppression.
      let owned = state.record.map { OwnedPanelContext(target: $0, disableReturned: true) }
      let power = Self.reconciledLifecycle(reading, current: lifecycle)
      let environment = ControllerObservation.environment(reading, power: power, owned: owned)
      send(.observed(.init(sequence: sequence, sampledAt: sampledAt, environment: environment)))
      if observeAgain {
        observeAgain = false
        observe()
      }
    }
  }

  /// A wake signal starts the transition and a usable observation completes it. Observation
  /// alone can never reinterpret `willSleep` as a completed wake.
  public nonisolated static func reconciledLifecycle(
    _ reading: PlatformReading, current: Power
  ) -> Power {
    let usable =
      reading.enumerationError == nil && !reading.displays.isEmpty
        && reading.foregroundSession == .yes && reading.displays
        .contains { $0.online && !$0.asleep }
    switch current {
    case .waking: return usable ? .awake : .waking
    case .sleeping: return .sleeping
    case .unknown: return usable ? .awake : .unknown
    case .awake: return .awake
    }
  }

  /// Repeated requests for the same instant share one timer.
  private func scheduleObservation(at instant: Instant, from now: Instant) {
    guard instant > now else {
      observe()
      return
    }
    guard scheduledObservations.insert(instant).inserted else { return }
    scheduler.after(Double(instant - now) / 1000) { [weak self] in
      self?.scheduledObservations.remove(instant)
      self?.observe()
    }
  }
}
