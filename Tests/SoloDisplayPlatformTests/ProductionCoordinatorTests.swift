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
  private let reads = Mutex(0)
  init(_ reading: PlatformReading) {
    value = .init(reading)
  }

  var readCount: Int {
    reads.withLock { $0 }
  }

  func read() -> PlatformReading {
    reads.withLock { $0 += 1 }
    return value.withLock { $0 }
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
  /// Every set of targets it has been told about, in order.
  var owed: [[PanelTarget]] = []
  var released = 0
  private var ready: (@MainActor () -> Void)?
  private var gone: (@MainActor () -> Void)?

  func spawn(
    targets: [PanelTarget], ready: @escaping @MainActor () -> Void,
    gone: @escaping @MainActor () -> Void
  ) {
    spawned.append(contentsOf: targets)
    self.ready = ready
    self.gone = gone
  }

  func update(targets: [PanelTarget]) {
    owed.append(targets)
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
  private var due: [(seconds: Double, fire: @MainActor () -> Void)] = []

  func after(_ seconds: Double, _ fire: @escaping @MainActor () -> Void) {
    wakes.append(seconds)
    due.append((seconds, fire))
  }

  /// Fires every wake asked for at this delay, the way one timer firing would.
  func fire(_ seconds: Double) {
    let firing = due.filter { $0.seconds == seconds }
    due.removeAll { $0.seconds == seconds }
    for wake in firing {
      wake.fire()
    }
  }

  private var repeating: (@MainActor () -> Void)?

  func startRepeating(_: Double, _ fire: @escaping @MainActor () -> Void) {
    repeating = fire
  }

  /// One turn of the controller's own timer, which is what decides whether a fresh reading is
  /// due. Sending a tick event alone skips that.
  func fireRepeating() {
    repeating?()
  }

  func stopRepeating() {
    repeating = nil
  }
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

/// Monitors that answer what they are showing, or do not answer at all.
private final class FakeInputSources: InputSourceObserving {
  private struct State {
    var evidence: [InputSourceEvidence] = []
    var calls = 0
    var answers = true
  }

  private let state = Mutex(State())
  private let held = DispatchSemaphore(value: 0)
  private let started = DispatchSemaphore(value: 0)

  var calls: Int {
    state.withLock { $0.calls }
  }

  /// A monitor showing the input this Mac is wired to, or another one, as the captured Dell
  /// replies do: the asking host's input in the high byte, what is on screen in the low byte.
  func showing(_ shown: ShownSource) {
    let reply: DDCValue? = switch shown {
    case .thisMac: .init(current: 0x1B1B, maximum: 0x1B1B)
    case .otherMachine: .init(current: 0x1B0F, maximum: 0x1B1B)
    case .unknown: nil
    }
    // Correlated, the way a monitor that has been seen at least once always is.
    let monitor = PanelTarget(
      displayID: 2, displayUUID: "external", bootID: "boot", loginID: 7
    )
    state.withLock {
      $0.evidence = [.init(controller: "dispext0", target: monitor, reply: reply)]
    }
  }

  /// A sweep that does not come back, the way a monitor that takes the bus and holds it behaves.
  /// It is released at the end of the test rather than left stalled for ever.
  func stopAnswering() {
    state.withLock { $0.answers = false }
  }

  func release() {
    held.signal()
  }

  /// Waits until a sweep has actually reached the monitor, since it runs on its own lane.
  func waitForSweep() {
    _ = started.wait(timeout: .now() + 5)
  }

  func read() -> [InputSourceEvidence] {
    let evidence = state.withLock { state -> [InputSourceEvidence]? in
      state.calls += 1
      return state.answers ? state.evidence : nil
    }
    started.signal()
    guard let evidence else {
      _ = held.wait(timeout: .now() + 10)
      return []
    }
    return evidence
  }
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
  let inputSources = FakeInputSources()
  let coordinator: ProductionCoordinator

  init(mode: Mode = .automatic, reading start: PlatformReading = reading(),
       asksMonitors: Bool = false, monitorsOnTheirOwnLane: Bool = false) {
    observer = FakeObserver(start)
    writer = FakeWriter(observer: observer)
    coordinator = ProductionCoordinator(
      state: .init(mode: mode), clock: clock, observer: observer, writer: writer,
      ownership: ownership, preferences: preferences, guardian: guardian, delegate: delegate,
      inputSources: asksMonitors ? inputSources : nil,
      lane: SyncLane(), storageLane: SyncLane(), workerLane: SyncLane(),
      inputLane: monitorsOnTheirOwnLane
        ? DispatchLane(label: "dev.solodisplay.test.input") : SyncLane(),
      scheduler: scheduler, diagnostics: .init(role: .app, sink: CapturedOperationalEvents())
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
    // A change that has not appeared yet is not a failure, and no second writer is started for
    // it: that is how two of them end up on the same panel at once.
    harness.step(to: 2700)
    #expect(harness.state.failures == 0)
    #expect(harness.writer.calls.count == 1)
    // Once the whole window has passed with nothing reported, it did not work.
    harness.step(to: 7200)
    #expect(harness.state.failures == 1)
    #expect(harness.coordinator.presentation.trouble == nil)
    harness.writer.answer(.done, changesDisplay: true)
    harness.step(to: 7800)
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
    // The record and the guardian are given up once the screen has stayed on, not on the one
    // reading that first shows it back.
    #expect(harness.guardian.released == 0)
    harness.step(to: 4400)
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

/// The monitors are asked over DDC, which is slow and can stall, so the sweep has its own lane,
/// its own answer, and a deadline. None of it may reach the reading lane or hold a decision open.
@MainActor
struct InputSourceCoordinatorTests {
  @Test func switchingTheMonitorAwayWhileOffTurnsTheScreenBackOn() {
    let harness = Harness(asksMonitors: true)
    harness.inputSources.showing(.thisMac)
    harness.turnOff()
    #expect(harness.writer.calls == [.init(enabled: false, displayID: 1)])

    harness.inputSources.showing(.otherMachine)
    harness.step(to: 12200)
    #expect(harness.writer.calls.count == 1)
    // The second answer agrees, so the screen comes back and nothing is owed any more.
    harness.step(to: 13300)
    #expect(harness.writer.calls.last == .init(enabled: true, displayID: 1))
    harness.step(to: 15500)
    #expect(harness.guardian.released == 1)
    #expect(
      harness.coordinator.presentation.unavailability == .monitorShowsAnotherMachine
    )
  }

  @Test func aMonitorShowingThisMacIsTurnedOffForAsBefore() {
    let harness = Harness(asksMonitors: true)
    harness.inputSources.showing(.thisMac)
    harness.turnOff()
    #expect(harness.writer.calls == [.init(enabled: false, displayID: 1)])
    #expect(harness.inputSources.calls >= 1)
  }

  @Test func aMonitorThatCannotAnswerIsTurnedOffForAsBefore() {
    let harness = Harness(asksMonitors: true)
    harness.inputSources.showing(.unknown)
    harness.turnOff()
    #expect(harness.writer.calls == [.init(enabled: false, displayID: 1)])
  }

  @Test func aSweepThatNeverAnswersIsGivenUpOnAfterTheDeadline() {
    let harness = Harness(asksMonitors: true, monitorsOnTheirOwnLane: true)
    harness.inputSources.stopAnswering()
    defer { harness.inputSources.release() }
    harness.step(to: 0)
    harness.inputSources.waitForSweep()
    // The deadline was scheduled, and firing it answers with nothing so the decision goes on.
    #expect(harness.scheduler.wakes.contains(5))
    harness.clock.set(5100)
    harness.scheduler.fire(5)
    harness.step(to: 5200)
    harness.guardian.becomeReady()
    #expect(harness.writer.calls == [.init(enabled: false, displayID: 1)])
  }

  @Test func aSecondSweepIsNeverStartedWhileOneIsOutstanding() {
    let harness = Harness(asksMonitors: true, monitorsOnTheirOwnLane: true)
    harness.inputSources.stopAnswering()
    defer { harness.inputSources.release() }
    harness.step(to: 0)
    harness.inputSources.waitForSweep()
    harness.step(to: 600)
    harness.step(to: 2100)
    #expect(harness.inputSources.calls == 1)
  }

  @Test func withNoMonitorsToAskNothingChanges() {
    let harness = Harness()
    harness.turnOff()
    #expect(harness.writer.calls == [.init(enabled: false, displayID: 1)])
    #expect(harness.inputSources.calls == 0)
  }
}

/// A monitor that has just come back is there before it can be told apart, and becoming
/// identifiable raises no display callback. An inconclusive reading is therefore looked at again
/// sooner, which changes when the answer is noticed and nothing about when anything is decided.
@MainActor
struct InconclusiveReadingTests {
  @Test func anInconclusiveReadingIsLookedAtAgainSooner() {
    let harness = Harness(reading: reading(externalTransport: .unclassified))
    harness.coordinator.start()
    harness.step(to: 0)
    let afterFirst = harness.observer.readCount
    // Well inside the ordinary two seconds.
    harness.clock.set(600)
    harness.scheduler.fireRepeating()
    #expect(harness.observer.readCount > afterFirst)
  }

  @Test func aConclusiveReadingIsLeftAloneForTheUsualInterval() {
    let harness = Harness()
    harness.coordinator.start()
    harness.step(to: 0)
    let afterFirst = harness.observer.readCount
    harness.clock.set(600)
    harness.scheduler.fireRepeating()
    #expect(harness.observer.readCount == afterFirst)
  }

  /// Looking more often must never let anything happen earlier. Turning the screen off waits on
  /// settling and on the monitors' own clock, and neither counts readings.
  @Test func lookingMoreOftenDecidesNothingSooner() {
    let harness = Harness(reading: reading(externalTransport: .unclassified))
    harness.coordinator.start()
    harness.step(to: 0)
    for instant in stride(from: 100, through: 1900, by: 100) {
      harness.clock.set(Instant(instant))
      harness.scheduler.fireRepeating()
    }
    // The arrangement was never usable, so nothing was turned off however often it was read.
    #expect(harness.writer.calls.isEmpty)
    #expect(harness.ownership.record == nil)
  }
}
