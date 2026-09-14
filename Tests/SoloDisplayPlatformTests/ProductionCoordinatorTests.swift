import Foundation
import SoloDisplayCore
import Synchronization
import Testing
@testable import SoloDisplayPlatform

// MARK: - Doubles

private final class FakeClock: CoordinatorClock {
  private let value = Mutex<Instant>(0)
  func now() -> Instant {
    value.withLock { $0 }
  }

  func set(_ instant: Instant) {
    value.withLock { $0 = instant }
  }
}

private final class FakeObserver: PlatformObserving {
  private let value: Mutex<PlatformReading>
  init(_ reading: PlatformReading) {
    value = .init(reading)
  }

  func read() -> PlatformReading {
    value.withLock { $0 }
  }

  func set(_ reading: PlatformReading) {
    value.withLock { $0 = reading }
  }

  /// What a display change does to the inventory: an off panel is simply not listed.
  func setPanelPresent(_ present: Bool) {
    value.withLock { reading in
      reading.displays.removeAll(where: \.builtIn)
      if present {
        reading.displays.insert(display(id: 1, builtIn: true), at: 0)
      }
    }
  }
}

private final class FakeWriter: DisplayWriting {
  struct Call: Equatable {
    var enabled: Bool
    var displayID: UInt32
  }

  private struct State {
    var calls: [Call] = []
    var outcome: WorkerOutcome = .done
    var changesDisplay = true
  }

  private let state = Mutex(State())
  let observer: FakeObserver

  init(observer: FakeObserver) {
    self.observer = observer
  }

  var calls: [Call] {
    state.withLock { $0.calls }
  }

  /// A worker that hangs or fails, and whether the display changed anyway.
  func answer(_ outcome: WorkerOutcome, changesDisplay: Bool) {
    state.withLock {
      $0.outcome = outcome
      $0.changesDisplay = changesDisplay
    }
  }

  func setEnabled(_ enabled: Bool, target: PanelTarget) -> WorkerOutcome {
    let (outcome, changes) = state.withLock {
      $0.calls.append(.init(enabled: enabled, displayID: target.displayID))
      return ($0.outcome, $0.changesDisplay)
    }
    if changes {
      observer.setPanelPresent(enabled)
    }
    return outcome
  }
}

private final class FakeOwnership: OwnershipPersisting {
  private struct State {
    var record: ProductionRecord?
    var clears = 0
  }

  private let state = Mutex(State())
  var record: ProductionRecord? {
    state.withLock { $0.record }
  }

  func prepare(_ record: ProductionRecord) throws {
    // The real store validates, so the fake must too, or a malformed record passes unnoticed.
    try record.validate()
    state.withLock { $0.record = record }
  }

  func clear() throws {
    state.withLock {
      $0.record = nil
      $0.clears += 1
    }
  }

  func reconcile(bootID: String?, loginID: UInt32?, displays _: [DisplayReading])
    -> JournalReconciliation {
    guard let record else { return .clean }
    return record.target.bootID == bootID && record.target.loginID == loginID
      ? .unresolved(record) : .priorSession(record)
  }
}

private final class FakePreferences: PreferencePersisting {
  let fails = Mutex(false)
  func save(mode _: Mode) throws {
    if fails.withLock({ $0 }) {
      throw JournalError.writeFailed
    }
  }
}

@MainActor private final class FakeGuardian: GuardianControlling {
  var spawned: [PanelTarget] = []
  var released = 0
  private var ready: (@MainActor () -> Void)?
  private var gone: (@MainActor () -> Void)?

  func spawn(
    target: PanelTarget, ready: @escaping @MainActor () -> Void,
    gone: @escaping @MainActor () -> Void
  ) {
    spawned.append(target)
    self.ready = ready
    self.gone = gone
  }

  func release() {
    released += 1
  }

  func becomeReady() {
    ready?()
  }

  func leave() {
    gone?()
  }
}

@MainActor private final class FakeDelegate: CoordinatorDelegate {
  var presentations: [Presentation] = []
  func coordinator(_: ProductionCoordinator, didUpdate presentation: Presentation) {
    presentations.append(presentation)
  }
}

/// Runs lane work immediately so ordering is deterministic.
private struct SyncLane: SerialLane {
  func run(
    _ work: @escaping @Sendable () -> Event,
    completion: @escaping @Sendable @MainActor (Event) -> Void
  ) {
    let event = work()
    MainActor.assumeIsolated { completion(event) }
  }

  func observe(
    _ work: @escaping @Sendable () -> PlatformReading,
    completion: @escaping @Sendable @MainActor (PlatformReading) -> Void
  ) {
    let reading = work()
    MainActor.assumeIsolated { completion(reading) }
  }
}

@MainActor private final class ManualScheduler: CoordinatorScheduler {
  var wakes: [Double] = []
  func after(_ seconds: Double, _: @escaping @MainActor () -> Void) {
    wakes.append(seconds)
  }

  func startRepeating(_: Double, _: @escaping @MainActor () -> Void) {}
  func stopRepeating() {}
}

// MARK: - Fixtures

private let panelTarget = PanelTarget(
  displayID: 1, displayUUID: "panel", bootID: "boot", loginID: 7
)

private func display(
  id: UInt32, builtIn: Bool, transport: DisplayTransport = .native
) -> DisplayReading {
  .init(
    id: id, uuid: builtIn ? "panel" : "external-\(id)", uuidResolvedID: id, builtIn: builtIn,
    active: true, online: true, asleep: false, mirrored: false, mirrorSourceID: nil,
    width: 1920, height: 1080, originX: 0, originY: 0, modeAvailable: true,
    transport: transport.rawValue
  )
}

private func reading(
  panel: Bool = true, external: Bool = true, externalTransport: DisplayTransport = .native
) -> PlatformReading {
  var displays: [DisplayReading] = []
  if panel {
    displays.append(display(id: 1, builtIn: true))
  }
  if external {
    displays.append(display(id: 5, builtIn: false, transport: externalTransport))
  }
  return PlatformReading(
    osVersion: "test", monotonicMilliseconds: 0, enumerationError: nil,
    displays: displays, lid: .open, bootID: "boot", loginID: 7, foregroundSession: .yes,
    privateSymbol: "SLSConfigureDisplayEnabled", limitations: []
  )
}

// MARK: - Harness

@MainActor private final class Harness {
  let clock = FakeClock()
  let observer: FakeObserver
  let writer: FakeWriter
  let ownership = FakeOwnership()
  let preferences = FakePreferences()
  let guardian = FakeGuardian()
  let delegate = FakeDelegate()
  let scheduler = ManualScheduler()
  let coordinator: ProductionCoordinator

  init(mode: Mode = .automatic, reading start: PlatformReading = reading()) {
    observer = FakeObserver(start)
    writer = FakeWriter(observer: observer)
    coordinator = ProductionCoordinator(
      state: .init(mode: mode), clock: clock, observer: observer, writer: writer,
      ownership: ownership, preferences: preferences, guardian: guardian, delegate: delegate,
      lane: SyncLane(), storageLane: SyncLane(), workerLane: SyncLane(), scheduler: scheduler,
      diagnostics: .init(role: .app, sink: CapturedOperationalEvents())
    )
  }

  /// A reading, a clock advance, and a tick, the way the running coordinator interleaves them.
  func step(to instant: Instant, reading value: PlatformReading? = nil) {
    if let value {
      observer.set(value)
    }
    clock.set(instant)
    coordinator.platformDidChange()
    coordinator.send(.tick)
  }

  /// Settles on the full interval and lets the guardian report ready.
  func turnOff() {
    step(to: 0)
    step(to: 600)
    step(to: 2100)
    guardian.becomeReady()
  }

  var state: ControllerState {
    coordinator.state
  }
}

// MARK: - Tests

@MainActor
struct ProductionCoordinatorTests {
  @Test func turningOffWritesTheRecordThenStartsAGuardianThenRunsAWorker() {
    let harness = Harness()
    harness.step(to: 0)
    harness.step(to: 600)
    harness.step(to: 2100)
    #expect(harness.ownership.record?.target == panelTarget)
    #expect(harness.ownership.record?.scope == "session")
    #expect(harness.ownership.record?.topology.count == 2)
    #expect(harness.guardian.spawned == [panelTarget])
    #expect(harness.writer.calls.isEmpty)
    harness.guardian.becomeReady()
    #expect(harness.writer.calls == [.init(enabled: false, displayID: 1)])
    #expect(harness.coordinator.presentation.panelOff)
    #expect(harness.state.failures == 0)
  }

  @Test func aWorkerThatHangsIsRetriedWithoutAFault() {
    let harness = Harness()
    harness.writer.answer(.killed, changesDisplay: false)
    harness.turnOff()
    #expect(harness.writer.calls.count == 1)
    #expect(harness.state.failures == 1)
    #expect(harness.coordinator.presentation.trouble == nil)
    harness.writer.answer(.done, changesDisplay: true)
    harness.step(to: 2700)
    #expect(harness.writer.calls.count == 2)
    #expect(harness.coordinator.presentation.panelOff)
    #expect(harness.state.failures == 0)
  }

  @Test func aHungWorkerWhoseChangeLandedCountsAsDone() {
    // The 13:21 incident: the screen changed, the call never returned.
    let harness = Harness()
    harness.writer.answer(.killed, changesDisplay: true)
    harness.turnOff()
    #expect(harness.coordinator.presentation.panelOff)
    #expect(harness.state.failures == 0)
    #expect(harness.guardian.released == 0)
  }

  @Test func unpluggingWhileOffTurnsTheScreenOnAndReleasesTheGuardian() {
    let harness = Harness()
    harness.turnOff()
    harness.step(to: 2200, reading: reading(panel: false, external: false))
    #expect(harness.writer.calls.last == .init(enabled: true, displayID: 1))
    #expect(harness.guardian.released == 1)
    #expect(harness.ownership.record == nil)
    #expect(!harness.coordinator.presentation.panelOff)
  }

  @Test func aGuardianThatExitsBringsTheScreenBack() {
    let harness = Harness()
    harness.turnOff()
    harness.guardian.leave()
    // The first attempt waits for the backoff rather than racing the guardian's exit.
    #expect(harness.writer.calls.count == 1)
    harness.step(to: 2700)
    #expect(harness.writer.calls.contains(.init(enabled: true, displayID: 1)))
  }

  @Test func anUnclassifiedTransportNeverReachesTheDisplay() {
    let harness = Harness(reading: reading(externalTransport: .unclassified))
    harness.turnOff()
    #expect(harness.writer.calls.isEmpty)
    #expect(harness.ownership.record == nil)
    #expect(harness.guardian.spawned.isEmpty)
    #expect(harness.coordinator.presentation.unavailability == .noNativeExternal)
  }

  @Test func aReportedReconfigurationStartsTurningOffWithoutTheFullInterval() {
    let harness = Harness()
    harness.coordinator.send(.displayReconfigured(inProgress: false))
    harness.step(to: 0)
    // One timer for the settling reading, however many reductions asked for it.
    #expect(harness.scheduler.wakes.filter { $0 == 0.5 }.count == 1)
    harness.step(to: 600)
    #expect(harness.guardian.spawned == [panelTarget])
  }

  @Test func aPreferenceFailureIsShownAndDoesNotBlockTheChoice() {
    let harness = Harness(mode: .automaticPaused)
    harness.preferences.fails.withLock { $0 = true }
    harness.step(to: 0)
    harness.coordinator.send(.selectMode(.automatic))
    #expect(harness.coordinator.presentation.trouble == .preferencesNotSaved)
    #expect(harness.state.wantsOff)
  }

  @Test func aLeftoverRecordIsClearedOnlyWhenThePanelIsVisiblyOn() throws {
    let ownership = FakeOwnership()
    var elsewhere = panelTarget
    elsewhere.bootID = "an-earlier-boot"
    try ownership.prepare(.init(
      session: "s", operationID: 1, target: elsewhere, scope: "session",
      controllerPID: 1, helperPID: 0, topology: []
    ))
    let dark = ProductionCoordinator.resolveRecord(ownership, reading: reading(panel: false))
    #expect(dark.blocked)
    #expect(ownership.record != nil)
    let lit = ProductionCoordinator.resolveRecord(ownership, reading: reading())
    #expect(!lit.blocked)
    #expect(lit.target == nil)
    #expect(ownership.record == nil)
  }

  @Test func aRecordFromThisSessionIsTakenOverRatherThanCleared() throws {
    let ownership = FakeOwnership()
    try ownership.prepare(.init(
      session: "s", operationID: 1, target: panelTarget, scope: "session",
      controllerPID: 1, helperPID: 0, topology: []
    ))
    let resolved = ProductionCoordinator.resolveRecord(ownership, reading: reading(panel: false))
    #expect(resolved.target == panelTarget)
    #expect(!resolved.blocked)
  }
}
