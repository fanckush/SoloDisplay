import Darwin
import Foundation
import LidlessCore

/// Raw values are the journal's vocabulary, so a record's scope round trips as written.
public enum DisplayScope: String, Sendable {
  case application = "app"
  case session = "session"
}

public protocol CoordinatorClock: Sendable {
  /// Monotonic milliseconds. A wall clock must never reach the reducer.
  func now() -> Instant
}

public protocol PlatformObserving: Sendable {
  func read() -> PlatformReading
}

public protocol DisplayWriting: Sendable {
  func setEnabled(_ enabled: Bool, displayID: UInt32, scope: DisplayScope) throws
}

public protocol OwnershipPersisting: Sendable {
  func prepare(_ record: ProductionRecord) throws
  func clear() throws
}

public protocol PreferencePersisting: Sendable {
  func save(mode: Mode) throws
}

/// One serial execution lane for synchronous platform calls. Results always come back, even
/// late, because a deadline that passed is not evidence that a call was cancelled.
public protocol SerialLane: Sendable {
  func run(
    _ work: @escaping @Sendable () -> Event,
    completion: @escaping @Sendable @MainActor (Event) -> Void)
  /// Reading and interpreting are separate on purpose: the reading happens off the loop, and
  /// what it means is decided on the loop with the ownership context that is current then.
  func observe(
    _ work: @escaping @Sendable () -> PlatformReading,
    completion: @escaping @Sendable @MainActor (PlatformReading) -> Void)
  func detached(_ work: @escaping @Sendable () -> Void)
}

@MainActor public protocol CoordinatorScheduler: AnyObject {
  func after(_ seconds: Double, _ fire: @escaping @MainActor () -> Void)
  func startRepeating(_ seconds: Double, _ fire: @escaping @MainActor () -> Void)
  func stopRepeating()
}

/// The production lane: one background queue, results delivered on the main actor.
public struct DispatchLane: SerialLane {
  private let queue = DispatchQueue(label: "dev.lidless.platform", qos: .userInitiated)
  public init() {}
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
  public func detached(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
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

/// The controller side of the protection protocol, as the coordinator needs it.
@MainActor public protocol ProtectionRequesting: AnyObject {
  var authorization: ProtectionAuthorization { get }
  func arm(operationID: UInt64, ownership: Ownership)
  func release()
  /// Outstanding-operation state for the next heartbeat, so a stall is visible to the helper.
  func noteOperation(_ progress: OperationProgress?)
}

@MainActor public protocol CoordinatorDelegate: AnyObject {
  func coordinator(_ coordinator: ProductionCoordinator, didUpdate presentation: Presentation)
  func coordinator(_ coordinator: ProductionCoordinator, didRecord event: RecordedEvent)
  func coordinatorIsReadyToExit(_ coordinator: ProductionCoordinator)
}

/// Runs the pure reducer against the real platform. Decisions happen here, on the main actor,
/// one event at a time. Every synchronous platform call runs on one serial lane instead, so a
/// stalled display call cannot block the event loop and callbacks never configure a display.
@MainActor
public final class ProductionCoordinator {
  public private(set) var state: ControllerState
  public var presentation: Presentation { Controller.presentation(state, at: clock.now()) }

  private let clock: any CoordinatorClock
  private let observer: any PlatformObserving
  private let writer: any DisplayWriting
  private let ownership: any OwnershipPersisting
  private let preferences: any PreferencePersisting
  private weak var protection: (any ProtectionRequesting)?
  private weak var delegate: (any CoordinatorDelegate)?

  private let lane: any SerialLane
  private let scheduler: any CoordinatorScheduler
  private var observationSequence: UInt64 = 0
  private var observationInFlight = false
  /// A disable request for the owned target actually returned. Absence means suppression only
  /// with this, never with ownership alone.
  private var ownedDisableReturned = false
  private var lifecycle: Power = .unknown
  private var lifecycleChangedAt: Instant = 0
  private let session: String
  private let disablePermit = DisablePermit()
  private var baseline: ProductionRecord?
  /// The scope actually used for a disable, recorded so recovery can match it.
  public var scope: DisplayScope = .application

  public init(
    state: ControllerState, clock: any CoordinatorClock, observer: any PlatformObserving,
    writer: any DisplayWriting, ownership: any OwnershipPersisting,
    preferences: any PreferencePersisting, protection: (any ProtectionRequesting)?,
    delegate: (any CoordinatorDelegate)?, lane: any SerialLane = DispatchLane(),
    scheduler: (any CoordinatorScheduler)? = nil, session: String = UUID().uuidString
  ) {
    self.lane = lane
    self.session = session
    self.scheduler = scheduler ?? TimerScheduler()
    self.state = state
    self.clock = clock
    self.observer = observer
    self.writer = writer
    self.ownership = ownership
    self.preferences = preferences
    self.protection = protection
    self.delegate = delegate
  }

  public func start() {
    lifecycle = .awake
    lifecycleChangedAt = clock.now()
    observe()
    // Refresh at least every two seconds, which also bounds how stale evidence can get.
    scheduler.startRepeating(0.5) { [weak self] in self?.tick() }
  }

  public func stop() { scheduler.stopRepeating() }

  // MARK: - Events

  /// The single entry point. Callbacks, notifications, user actions, and lane results all
  /// arrive here and are reduced one at a time.
  public func send(_ event: Event) {
    let now = clock.now()
    switch event {
    case .willSleep:
      lifecycle = .sleeping
      lifecycleChangedAt = now
    case .waking:
      lifecycle = .waking
      lifecycleChangedAt = now
    default: break
    }
    if case .observed(let sample) = event, sample.environment.power != lifecycle {
      lifecycle = sample.environment.power
      lifecycleChangedAt = now
    }
    // A returned disable is what makes a later absence readable as our own suppression.
    if case .operationReturned(let id, _) = event, state.operation?.id == id,
      state.operation?.kind == .disable
    {
      ownedDisableReturned = true
    }
    let transition = Controller.reduce(state, event, at: now)
    state = transition.state
    disablePermit.update(state, at: now)
    if state.ownership == nil && state.operation == nil {
      ownedDisableReturned = false
      baseline = nil
    }
    delegate?.coordinator(self, didRecord: .init(at: now, event: event))
    protection?.noteOperation(
      state.operation.map {
        .init(id: $0.id, kind: $0.kind, phase: $0.phase, deadline: $0.deadline)
      })
    for effect in transition.effects { execute(effect, at: now) }
    delegate?.coordinator(self, didUpdate: Controller.presentation(state, at: now))
  }

  /// A display callback or workspace notification only ever schedules work. It never writes.
  public func platformDidChange() { observe() }

  private func tick() {
    let now = clock.now()
    if let sample = state.observation, now - sample.sampledAt >= 2_000 { observe() }
    send(.tick)
  }

  // MARK: - Effects

  private func execute(_ effect: Effect, at now: Instant) {
    switch effect {
    case .observe:
      observe()
    case .savePreferences(let mode):
      let preferences = preferences
      onLane {
        do {
          try preferences.save(mode: mode)
          return .preferencesSaved(mode: mode, succeeded: true)
        } catch { return .preferencesSaved(mode: mode, succeeded: false) }
      }
    case .saveOwnership(let owned):
      prepareOwnership(owned)
    case .clearOwnership:
      let ownership = ownership
      onLane { [ownership] in
        do {
          try ownership.clear()
          return .ownershipCleared(succeeded: true)
        } catch {
          return .ownershipCleared(succeeded: false)
        }
      }
    case .armProtection(let id, let owned):
      guard let protection else {
        send(.protectionArmed(operationID: id, succeeded: false))
        return
      }
      protection.arm(operationID: id, ownership: owned)
    case .releaseProtection:
      protection?.release()
      ownedDisableReturned = false
    case .setPanelEnabled(let id, let target, let enabled):
      write(operationID: id, target: target, enabled: enabled)
    case .writerUnresponsive:
      // The helper learns this from the operation deadline it already receives each second.
      break
    case .wakeAt(let instant):
      scheduleWake(at: instant, from: now)
    case .exitReady:
      delegate?.coordinatorIsReadyToExit(self)
    }
  }

  private func prepareOwnership(_ owned: Ownership) {
    let reading = currentReading()
    let record = ProductionRecord(
      session: session, operationID: owned.operationID, target: owned.target,
      scope: scope.rawValue, controllerPID: ProcessInfo.processInfo.processIdentifier,
      helperPID: getppid(), topology: reading.displays)
    let ownership = ownership
    baseline = record
    onLane { [ownership] in
      do {
        try ownership.prepare(record)
        return .journalSaved(operationID: owned.operationID, succeeded: true)
      } catch {
        return .journalSaved(operationID: owned.operationID, succeeded: false)
      }
    }
  }

  /// The final eligibility check happens on the lane, immediately before the write, because
  /// anything decided earlier is already history by the time the call is made.
  private func write(operationID: UInt64, target: PanelTarget, enabled: Bool) {
    let writer = writer
    let observer = observer
    let scope = scope
    let permit = disablePermit
    let authorization = protection?.authorization
    let clock = clock
    let owned = state.ownership
    onLane { [writer, observer] in
      if !enabled {
        let reading = observer.read()
        let environment = ControllerObservation.environment(reading, power: .awake)
        guard environment.panel == target, environment.prerequisitesMet,
          environment.panelState == .enabled
        else {
          // Refusing before the call is different from a call that failed: nothing was sent.
          return .operationRefused(operationID: operationID)
        }
        guard let owned, authorization?.permits(owned, at: clock.now()) == true,
          permit.consume(operationID: operationID, target: target, at: clock.now())
        else { return .operationRefused(operationID: operationID) }
      } else {
        guard
          (try? RecoveryIdentity.authorizeRestore(
            observer.read(), target: target,
            liveOwnership: owned)) != nil
        else {
          return .restoreDeferred(operationID: operationID)
        }
      }
      do {
        try writer.setEnabled(enabled, displayID: target.displayID, scope: scope)
        return .operationReturned(operationID: operationID, succeeded: true)
      } catch {
        // An error does not establish that nothing changed, so ownership is kept either way.
        return .operationReturned(operationID: operationID, succeeded: false)
      }
    }
  }

  // MARK: - Observation

  private func observe() {
    guard !observationInFlight else { return }
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
      self.observationInFlight = false
      // Ownership context is read here, not at dispatch. A reading that arrives after a disable
      // returned must be interpreted with that knowledge, or an owned panel reads as missing.
      let owned = self.state.ownership.map {
        OwnedPanelContext(target: $0.target, disableReturned: self.ownedDisableReturned)
      }
      let power = Self.reconciledLifecycle(
        reading, current: self.lifecycle, changedAt: self.lifecycleChangedAt, at: sampledAt)
      var environment = ControllerObservation.environment(reading, power: power, owned: owned)
      if let baseline = self.baseline, self.state.ownership != nil {
        environment.restorationMatches = RestorationVerification.matches(baseline, reading: reading)
      }
      self.send(
        .observed(
          .init(
            sequence: sequence, sampledAt: sampledAt,
            environment: environment)))
    }
  }

  /// An independent path back to a usable lifecycle state. A missed workspace notification must
  /// not leave the coordinator believing the machine is asleep for the rest of the run, and a
  /// wake notification on its own never establishes that anything is usable yet.
  nonisolated public static func reconciledLifecycle(
    _ reading: PlatformReading, current: Power, changedAt: Instant, at now: Instant
  ) -> Power {
    let usable =
      reading.enumerationError == nil && !reading.displays.isEmpty
      && reading.foregroundSession == .yes && reading.displays.contains { $0.online && !$0.asleep }
    switch current {
    case .waking: return usable ? .awake : .waking
    // Two seconds of usable evidence outrank a sleep notification that was never followed by a
    // wake. This is reconciliation from observation, not an assumption about timing.
    case .sleeping: return usable && now - changedAt >= 2_000 ? .awake : .sleeping
    case .unknown: return usable ? .awake : .unknown
    case .awake: return .awake
    }
  }

  private func currentReading() -> PlatformReading { observer.read() }

  private func scheduleWake(at instant: Instant, from now: Instant) {
    scheduler.after(Double(max(instant - now, 0)) / 1_000) { [weak self] in self?.send(.tick) }
  }

  private func onLane(_ work: @escaping @Sendable () -> Event) {
    // A late result is still a real result. It is delivered and the reducer decides.
    lane.run(work) { [weak self] event in self?.send(event) }
  }
}
