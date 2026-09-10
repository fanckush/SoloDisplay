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

  func advance(_ by: Instant) {
    value.withLock { $0 += by }
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
}

private final class FakeWriter: DisplayWriting {
  struct Call: Equatable {
    var enabled: Bool
    var displayID: UInt32
    var scope: DisplayScope
  }

  struct State {
    var calls: [Call] = []
    var failEnabled: Set<Bool> = []
  }

  let state = Mutex(State())
  var calls: [Call] {
    state.withLock { $0.calls }
  }

  func failWrites(enabled: Bool) {
    _ = state.withLock { $0.failEnabled.insert(enabled) }
  }

  func setEnabled(_ enabled: Bool, displayID: UInt32, scope: DisplayScope) throws {
    let shouldFail = state.withLock {
      $0.calls.append(.init(enabled: enabled, displayID: displayID, scope: scope))
      return $0.failEnabled.contains(enabled)
    }
    if shouldFail {
      throw DisplayAPIError.unavailable
    }
  }
}

private final class FakeOwnership: OwnershipPersisting {
  struct State {
    var record: ProductionRecord?
    var prepareFails = false
    var clearFails = false
    var prepares = 0
    var clears = 0
  }

  let state = Mutex(State())
  var record: ProductionRecord? {
    state.withLock { $0.record }
  }

  var clears: Int {
    state.withLock { $0.clears }
  }

  func failPrepare() {
    state.withLock { $0.prepareFails = true }
  }

  func failClear(_ value: Bool) {
    state.withLock { $0.clearFails = value }
  }

  func prepare(_ record: ProductionRecord) throws {
    // The real store validates, so the fake must too, or a malformed record passes unnoticed.
    try record.validate()
    try state.withLock {
      $0.prepares += 1
      if $0.prepareFails {
        throw JournalError.writeFailed
      }
      guard $0.record == nil else { throw JournalError.alreadyExists }
      $0.record = record
    }
  }

  func clear() throws {
    try state.withLock {
      $0.clears += 1
      if $0.clearFails {
        throw JournalError.clearFailed
      }
      $0.record = nil
    }
  }
}

private final class FakePreferences: PreferencePersisting {
  let saved = Mutex<[Mode]>([])
  let fails = Mutex(false)
  func save(mode: Mode) throws {
    if fails.withLock({ $0 }) {
      throw JournalError.writeFailed
    }
    saved.withLock { $0.append(mode) }
  }
}

@MainActor private final class FakeProtection: ProtectionRequesting {
  let authorization = ProtectionAuthorization()
  var armed: [UInt64] = []
  var releases = 0
  var progress: [OperationProgress?] = []
  func arm(operationID: UInt64, ownership: Ownership) {
    armed.append(operationID)
    var protocolState = ControllerProtection(session: "test", at: 0)
    protocolState.receive(.start, at: 0)
    protocolState.receive(
      .received(
        .init(
          session: "test", sender: .helper,
          sequence: 1, kind: .witness
        )
      ), at: 0
    )
    protocolState.receive(.arm(ownership), at: 2100)
    protocolState.receive(
      .received(
        .init(
          session: "test", sender: .helper,
          sequence: 2, challenge: 1, kind: .armed, ownership: ownership
        )
      ), at: 2100
    )
    authorization.update(protocolState)
  }

  func release() {
    releases += 1
  }

  func noteOperation(_ progress: OperationProgress?) {
    self.progress.append(progress)
  }
}

@MainActor private final class FakeDelegate: CoordinatorDelegate {
  var presentations: [Presentation] = []
  var recorded: [RecordedEvent] = []
  var readyToExit = 0
  func coordinator(_: ProductionCoordinator, didUpdate presentation: Presentation) {
    presentations.append(presentation)
  }

  func coordinator(_: ProductionCoordinator, didRecord event: RecordedEvent) {
    recorded.append(event)
  }

  func coordinatorIsReadyToExit(_: ProductionCoordinator) {
    readyToExit += 1
  }
}

/// Runs lane work immediately so ordering is deterministic. The coordinator still treats it as
/// a separate lane, which is what the production code depends on.
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

  func detached(_ work: @escaping @Sendable () -> Void) {
    work()
  }
}

/// Unlike SyncLane this leaves work queued while notifications and user actions are reduced.
private final class DelayedLane: SerialLane {
  private let pending = Mutex<[@Sendable @MainActor () -> Void]>([])
  func run(
    _ work: @escaping @Sendable () -> Event,
    completion: @escaping @Sendable @MainActor (Event) -> Void
  ) {
    pending.withLock { $0.append { completion(work()) } }
  }

  func observe(
    _ work: @escaping @Sendable () -> PlatformReading,
    completion: @escaping @Sendable @MainActor (PlatformReading) -> Void
  ) {
    let reading = work()
    MainActor.assumeIsolated { completion(reading) }
  }

  func detached(_ work: @escaping @Sendable () -> Void) {
    work()
  }

  @MainActor func flush() {
    while let next = pending.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
      next()
    }
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
  id: UInt32, builtIn: Bool, active: Bool = true, mirrored: Bool = false, source: UInt32? = nil,
  transport: DisplayTransport = .native
) -> DisplayReading {
  .init(
    id: id, uuid: builtIn ? "panel" : "external-\(id)", uuidResolvedID: id, builtIn: builtIn,
    active: active, online: true, asleep: false, mirrored: mirrored, mirrorSourceID: source,
    width: 1920, height: 1080, originX: 0, originY: 0, modeAvailable: true,
    transport: transport.rawValue
  )
}

private func reading(
  panel: Bool = true, panelActive: Bool = true, external: Bool = true,
  externalTransport: DisplayTransport = .native, foreground: Fact = .yes, lid: Lid = .open,
  validated: Bool = true, enumerationError: Int32? = nil
) -> PlatformReading {
  var displays: [DisplayReading] = []
  if panel {
    displays.append(display(id: 1, builtIn: true, active: panelActive))
  }
  if external {
    displays.append(display(id: 5, builtIn: false, transport: externalTransport))
  }
  var result = PlatformReading(
    osVersion: "test", monotonicMilliseconds: 0, enumerationError: enumerationError,
    displays: displays, lid: lid, bootID: "boot", loginID: 7, foregroundSession: foreground,
    privateSymbol: "SLSConfigureDisplayEnabled", limitations: []
  )
  result.backendValidated = validated
  return result
}

// MARK: - Harness

@MainActor private final class Harness {
  let clock = FakeClock()
  let observer: FakeObserver
  let writer = FakeWriter()
  let ownership = FakeOwnership()
  let preferences = FakePreferences()
  let protection = FakeProtection()
  let delegate = FakeDelegate()
  let scheduler = ManualScheduler()
  let diagnostics = CapturedOperationalEvents()
  let coordinator: ProductionCoordinator

  init(
    mode: Mode = .automatic, reading start: PlatformReading = reading(),
    lane: any SerialLane = SyncLane()
  ) {
    observer = FakeObserver(start)
    var state = ControllerState(mode: mode)
    state.protectionAvailable = true
    coordinator = ProductionCoordinator(
      state: state, clock: clock, observer: observer, writer: writer, ownership: ownership,
      preferences: preferences, protection: protection, delegate: delegate,
      lane: lane, scheduler: scheduler,
      diagnostics: .init(role: .controller, sink: diagnostics)
    )
    coordinator.send(.protectionAvailable(true))
  }

  /// Observation, clock advance, and a tick, the way the running coordinator interleaves them.
  func step(to instant: Instant, reading value: PlatformReading? = nil) {
    if let value {
      observer.set(value)
    }
    clock.set(instant)
    coordinator.platformDidChange()
    coordinator.send(.tick)
  }

  /// Completes the arm the coordinator requested, as the helper would.
  func grantProtection() {
    guard let id = protection.armed.last else { return }
    coordinator.send(.protectionArmed(operationID: id, succeeded: true))
  }

  func reachSuppression() {
    step(to: 0)
    step(to: 600)
    step(to: 2100)
    grantProtection()
  }

  var state: ControllerState {
    coordinator.state
  }
}

// MARK: - Tests

@MainActor
struct ProductionCoordinatorTests {
  @Test(arguments: [Lid.closed, .unknown])
  func unavailableLidDoesNotExhaustRecovery(_ lid: Lid) {
    let harness = Harness()
    harness.reachSuppression()
    harness.step(to: 2200, reading: reading(panel: false))
    for time in stride(from: Instant(2400), through: 20000, by: 500) {
      harness.step(to: time, reading: reading(panel: false, lid: lid))
    }
    #expect(harness.state.restoreAttempts == 0)
    #expect(harness.state.ownership != nil)
    #expect(harness.coordinator.presentation.waitingForRecovery)
    harness.step(to: 21000, reading: reading(panel: false, external: false))
    #expect(harness.writer.calls.filter(\.enabled).count == 1)
    harness.step(to: 21500, reading: reading(external: false))
    #expect(harness.state.ownership == nil)
  }

  @Test func aQueuedRestoreDefersWhenTheSessionDisappearsBeforeItsCall() {
    let lane = DelayedLane()
    let harness = Harness(lane: lane)
    harness.step(to: 0)
    harness.step(to: 600)
    harness.step(to: 2100)
    lane.flush()
    harness.grantProtection()
    lane.flush()
    harness.step(to: 2200, reading: reading(panel: false))
    harness.coordinator.send(.keepOn)
    harness.observer.set(reading(panel: false, foreground: .no))
    lane.flush()
    #expect(harness.state.restoreAttempts == 0)
    #expect(harness.state.recoveryDeferredSequence != nil)
    #expect(harness.writer.calls.filter(\.enabled).isEmpty)
    harness.step(to: 3000, reading: reading(panel: false, external: false))
    lane.flush()
    #expect(harness.writer.calls.filter(\.enabled).count == 1)
    harness.step(to: 3500, reading: reading(external: false))
    lane.flush()
    #expect(harness.state.ownership == nil)
  }

  @Test func aQueuedRestoreCannotCrossACompleteSleepWakeGeneration() {
    let lane = DelayedLane()
    let harness = Harness(lane: lane)
    harness.step(to: 0)
    harness.step(to: 600)
    harness.step(to: 2100)
    lane.flush()
    harness.grantProtection()
    lane.flush()
    harness.step(to: 2200, reading: reading(panel: false))

    harness.coordinator.send(.keepOn) // Queue restore under the current awake generation.
    harness.coordinator.send(.willSleep)
    harness.coordinator.send(.waking)
    harness.step(to: 3000, reading: reading(panel: false)) // Establish a new awake generation.
    lane.flush()

    // Reopening the gate does not revive the request that was authorized before sleep.
    #expect(harness.writer.calls.filter(\.enabled).isEmpty)
    #expect(harness.state.recoveryDeferredSequence != nil)

    harness.step(to: 3600, reading: reading(panel: false))
    lane.flush()
    #expect(harness.writer.calls.filter(\.enabled).count == 1)
  }

  @Test(arguments: [Event.keepOn, .willSleep, .protectionAvailable(false), .quit])
  func queuedDisableIsRevokedBeforeItsCall(_ interruption: Event) {
    let lane = DelayedLane()
    let harness = Harness(lane: lane)
    harness.step(to: 0)
    harness.step(to: 600)
    harness.step(to: 2100)
    lane.flush() // Persist the journal and request the lease.
    harness.grantProtection() // Queue a write but do not run it.
    harness.coordinator.send(interruption)
    lane.flush()
    #expect(harness.writer.calls.isEmpty)
    #expect(harness.ownership.record == nil)
  }

  @Test func queuedDisableCannotOutliveItsLeaseOrOperationDeadline() {
    let lane = DelayedLane()
    let harness = Harness(lane: lane)
    harness.step(to: 0)
    harness.step(to: 600)
    harness.step(to: 2100)
    lane.flush()
    harness.grantProtection()
    harness.clock.set(10000) // No main-loop tick to announce expiry.
    lane.flush()
    #expect(harness.writer.calls.isEmpty)
  }

  @Test func preferenceFailureIsVisibleAndInhibitsAutomaticDisabling() {
    let harness = Harness()
    harness.preferences.fails.withLock { $0 = true }
    harness.coordinator.send(.keepOn)
    #expect(harness.state.mode == .automaticPaused)
    #expect(harness.state.fault == .preferencesFailed)
    harness.reachSuppression()
    #expect(harness.writer.calls.isEmpty)
  }

  @Test func changedMirrorRelationshipRetainsOwnershipAfterRestore() {
    var mirrored = reading()
    mirrored.displays[0].active = false
    mirrored.displays[0].mirrored = true
    mirrored.displays[0].mirrorSourceID = 5
    mirrored.displays[1].mirrored = true
    let harness = Harness(reading: mirrored)
    harness.reachSuppression()
    harness.step(to: 2200, reading: reading(panel: false))
    harness.coordinator.send(.keepOn)
    harness.step(to: 2400, reading: reading()) // Panel is back, but incorrectly extended.
    #expect(harness.state.ownership != nil)
    #expect(harness.ownership.clears == 0)
    #expect(harness.state.fault == .configurationChanged)
  }

  @Test func aFullDisableWalksJournalThenLeaseThenWrite() {
    let harness = Harness()
    harness.reachSuppression()
    #expect(harness.ownership.record?.target == panelTarget)
    #expect(harness.ownership.record?.scope == "app")
    #expect(harness.protection.armed.count == 1)
    #expect(harness.writer.calls == [.init(enabled: false, displayID: 1, scope: .application)])
    // The record captures the topology recovery has to verify against.
    #expect(harness.ownership.record?.topology.count == 2)
  }

  @Test func anUnclassifiedTransportNeverReachesTheDisplay() {
    let harness = Harness(reading: reading(externalTransport: .unclassified))
    harness.reachSuppression()
    #expect(harness.writer.calls.isEmpty)
    #expect(harness.ownership.record == nil)
    #expect(harness.coordinator.presentation.unavailability == .noNativeExternal)
  }

  @Test func anUnvalidatedBackendNeverReachesTheDisplay() {
    let harness = Harness(reading: reading(validated: false))
    harness.reachSuppression()
    #expect(harness.writer.calls.isEmpty)
    #expect(harness.coordinator.presentation.unavailability == .backendUnvalidated)
  }

  @Test func aStorageFailureFaultsInsteadOfWriting() {
    let harness = Harness()
    harness.ownership.failPrepare()
    harness.reachSuppression()
    #expect(harness.writer.calls.isEmpty)
    #expect(harness.state.fault == .journalFailed)
    #expect(harness.coordinator.presentation.unavailability == .faulted)
  }

  @Test func aRefusedLeaseClearsTheRecordWithoutWriting() throws {
    let harness = Harness()
    harness.step(to: 0)
    harness.step(to: 600)
    harness.step(to: 2100)
    let id = try #require(harness.protection.armed.last)
    harness.coordinator.send(.protectionArmed(operationID: id, succeeded: false))
    #expect(harness.writer.calls.isEmpty)
    #expect(harness.state.fault == .protectionUnavailable)
    #expect(harness.ownership.record == nil)
  }

  @Test func theExecutorRechecksEligibilityImmediatelyBeforeWriting() {
    let harness = Harness()
    harness.step(to: 0)
    harness.step(to: 600)
    harness.step(to: 2100)
    // The external disappears between the decision and the call itself.
    harness.observer.set(reading(external: false))
    harness.grantProtection()
    // Refusing before the call is positive knowledge that nothing was touched, so there is
    // nothing to undo and no reason to send a restore.
    #expect(harness.writer.calls.isEmpty)
    #expect(harness.state.fault == .operationRefused)
    #expect(harness.state.ownership == nil)
    #expect(harness.ownership.record == nil)
  }

  @Test func losingTheExternalRestoresAndReleasesOnlyAfterAConfirmedClear() {
    let harness = Harness()
    harness.reachSuppression()
    harness.step(to: 2200, reading: reading(panel: false))
    #expect(harness.state.ownership != nil)

    // Losing the last external removes a prerequisite, so restoration is immediate.
    harness.step(to: 2400, reading: reading(panel: false, external: false))
    #expect(harness.writer.calls.contains(.init(enabled: true, displayID: 1, scope: .application)))
    #expect(harness.state.ownership != nil)

    harness.step(to: 2600, reading: reading(external: false))
    #expect(harness.state.ownership == nil)
    #expect(harness.ownership.clears == 1)
    #expect(harness.protection.releases >= 1)
  }

  @Test func aFailedClearKeepsOwnershipAndBlocksNewDisabling() {
    let harness = Harness()
    harness.reachSuppression()
    harness.step(to: 2200, reading: reading(panel: false))
    harness.ownership.failClear(true)
    harness.step(to: 2400, reading: reading(panel: false, external: false))
    harness.step(to: 2600, reading: reading(external: false))
    #expect(harness.state.fault == .ownershipClearFailed)
    #expect(harness.state.ownership != nil)
    #expect(harness.coordinator.presentation.pendingRecovery)
    #expect(
      harness.diagnostics.events.contains { $0.code == .journalCleared && $0.succeeded == false }
    )
  }

  @Test func losingTheHelperRestoresTheOwnedPanel() {
    let harness = Harness()
    harness.reachSuppression()
    harness.step(to: 2200, reading: reading(panel: false))
    harness.coordinator.send(.protectionAvailable(false))
    #expect(harness.writer.calls.contains(.init(enabled: true, displayID: 1, scope: .application)))
    #expect(harness.state.fault == .protectionLost)
  }

  @Test func aWriteErrorIsFollowedByRestorationRatherThanForgottenOwnership() {
    let harness = Harness()
    harness.writer.failWrites(enabled: false)
    harness.reachSuppression()
    #expect(harness.state.fault == .operationFailed)
    // An error is not proof that nothing happened, so the panel is put back rather than dropped.
    #expect(
      harness.writer.calls == [
        .init(enabled: false, displayID: 1, scope: .application),
        .init(enabled: true, displayID: 1, scope: .application)
      ]
    )
    // Ownership is released only after the panel is observed back and the record is really gone.
    #expect(harness.state.ownership == nil)
    #expect(harness.ownership.record == nil)
    #expect(harness.ownership.clears == 1)
    #expect(
      harness.diagnostics.events.contains { $0.code == .operationReturned && $0.succeeded == false }
    )
  }

  @Test func aStaleCompletionCannotHideOrRepeatAWrite() throws {
    let harness = Harness()
    harness.reachSuppression()
    let id = try #require(harness.state.operation?.id)
    let before = harness.writer.calls.count
    // Replays and results for operations that no longer exist change nothing.
    harness.coordinator.send(.operationReturned(operationID: id, succeeded: true))
    harness.coordinator.send(.operationReturned(operationID: id + 99, succeeded: false))
    harness.coordinator.send(.journalSaved(operationID: id, succeeded: true))
    harness.coordinator.send(.protectionArmed(operationID: id, succeeded: true))
    #expect(harness.writer.calls.count == before)
  }

  @Test func activityAloneCannotMasqueradeAsAWakeTransition() {
    let harness = Harness()
    harness.reachSuppression()
    harness.coordinator.send(.willSleep)
    harness.step(to: 3000, reading: reading(panel: false, external: false, foreground: .no))
    #expect(harness.state.observation?.environment.power == .sleeping)
    // Continued callbacks during willSleep are not evidence that the display stack is writable.
    harness.step(to: 6000, reading: reading())
    #expect(harness.state.observation?.environment.power == .sleeping)
    #expect(harness.writer.calls.filter(\.enabled).isEmpty)
  }

  @Test func aWakeNotificationAloneDoesNotEstablishAUsableDisplay() {
    let harness = Harness()
    harness.step(to: 0)
    harness.coordinator.send(.willSleep)
    // Nothing is usable yet when the wake notification arrives.
    harness.observer.set(reading(panel: false, external: false, foreground: .no))
    harness.coordinator.send(.waking)
    harness.step(to: 100)
    #expect(harness.state.observation?.environment.power == .waking)
    #expect(harness.writer.calls.isEmpty)
  }

  @Test func sleepingClearsIntentAndForbidsNewDisabling() {
    let harness = Harness(mode: .manual)
    harness.coordinator.send(.manualOff)
    harness.coordinator.send(.willSleep)
    harness.step(to: 3000, reading: reading(foreground: .no))
    #expect(!harness.state.manualRequest)
    #expect(harness.writer.calls.isEmpty)
  }

  @Test func recoveryConvergesOnceThePlatformAcceptsRestoration() {
    let harness = Harness()
    harness.reachSuppression()
    harness.step(to: 2200, reading: reading(panel: false))

    // Restoration is refused while the environment cannot accept it.
    harness.writer.failWrites(enabled: true)
    harness.step(to: 2400, reading: reading(panel: false, external: false))
    #expect(harness.state.ownership != nil)

    harness.writer.state.withLock { $0.failEnabled.removeAll() }
    var settled = false
    for instant in stride(from: Instant(2600), through: 12000, by: 400) {
      harness.step(to: instant, reading: reading(external: false))
      if harness.state.ownership == nil {
        settled = true
        break
      }
    }
    #expect(settled)
    #expect(harness.ownership.record == nil)
  }

  @Test func everyDecisionIsRecordedForReplay() throws {
    let harness = Harness()
    harness.reachSuppression()
    var initial = ControllerState(mode: .automatic)
    initial.protectionAvailable = true
    let trace = ReplayTrace(initial: initial, events: harness.delegate.recorded)
    // The recorded stream reproduces exactly the state the live coordinator reached.
    #expect(try trace.replay().last?.state == harness.state)
  }

  @Test func heartbeatsCarryTheOutstandingOperationDeadline() {
    let harness = Harness()
    harness.reachSuppression()
    let reported = harness.protection.progress.compactMap(\.self)
    #expect(reported.contains { $0.phase == .arming })
    #expect(reported.contains { $0.phase == .submitted && $0.kind == .disable })
  }

  @Test func quitWaitsForRestorationAndAConfirmedClear() {
    let harness = Harness()
    harness.reachSuppression()
    harness.step(to: 2200, reading: reading(panel: false))
    #expect(harness.state.ownership != nil)

    harness.coordinator.send(.quit)
    // The panel is still absent, so restoration is not verified and the app must not exit.
    #expect(harness.delegate.readyToExit == 0)

    harness.step(to: 2400, reading: reading())
    #expect(harness.delegate.readyToExit >= 1)
    #expect(harness.state.ownership == nil)
    #expect(harness.ownership.record == nil)
    let codes = harness.diagnostics.events.map(\.code)
    #expect(codes.contains(.operationStarted))
    #expect(codes.contains(.operationReturned))
    #expect(codes.contains(.operationVerified))
    #expect(codes.last == .journalCleared)
  }

  @Test func quittingWithoutOwnershipDoesNotStartAnyWrite() {
    let harness = Harness()
    harness.step(to: 0)
    harness.coordinator.send(.quit)
    #expect(harness.writer.calls.isEmpty)
    #expect(harness.delegate.readyToExit >= 1)
  }

  @Test func aPausedAutomaticChoiceIsPersistedThroughTheCoordinator() {
    let harness = Harness(mode: .automatic)
    harness.step(to: 0)
    harness.coordinator.send(.keepOn)
    #expect(harness.preferences.saved.withLock { $0 } == [.automaticPaused])
    #expect(harness.state.mode == .automaticPaused)
    // A paused choice must not keep disabling.
    harness.step(to: 600)
    harness.step(to: 2100)
    #expect(harness.writer.calls.isEmpty)
  }
}
