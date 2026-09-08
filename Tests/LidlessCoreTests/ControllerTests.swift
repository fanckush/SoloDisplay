import Foundation
import Testing

@testable import LidlessCore

let panel = PanelTarget(displayID: 1, displayUUID: "panel-1", bootID: "boot-1", loginID: 42)

func environment(
  panelState: PanelState = .enabled, external: Fact = .yes,
  power: Power = .awake, lid: Lid = .open, backend: Fact = .yes
) -> Environment {
  .init(
    panel: panel, panelState: panelState, power: power, lid: lid,
    foregroundSession: .yes, nativeExternalAvailable: external,
    supportedTopology: .yes, backendValidated: backend)
}

struct Rig {
  var state: ControllerState
  var sequence: UInt64 = 0
  var trace: ReplayTrace
  init(mode: Mode = .automatic, protected: Bool = true) {
    state = .init(mode: mode)
    // A paired recovery helper is a precondition for disabling, so most tests start with one.
    state.protectionAvailable = protected
    trace = .init(initial: state, events: [])
  }
  @discardableResult mutating func send(_ event: Event, at time: Instant) -> [Effect] {
    trace.events.append(.init(at: time, event: event))
    let transition = Controller.reduce(state, event, at: time)
    state = transition.state
    return transition.effects
  }
  @discardableResult mutating func observe(_ value: Environment = environment(), at time: Instant)
    -> [Effect]
  {
    sequence += 1
    return send(.observed(.init(sequence: sequence, sampledAt: time, environment: value)), at: time)
  }
  mutating func prepare() {
    observe(at: 0)
    observe(at: 2_000)
  }
  mutating func disabled() {
    prepare()
    let id = state.operation!.id
    send(.journalSaved(operationID: id, succeeded: true), at: 2_001)
    send(.protectionArmed(operationID: id, succeeded: true), at: 2_002)
    send(.operationReturned(operationID: id, succeeded: true), at: 2_010)
    observe(environment(panelState: .disabled), at: 2_020)
  }
  /// Ownership is only released by a confirmed clear, so tests must complete that step.
  @discardableResult mutating func cleared(at time: Instant) -> [Effect] {
    send(.ownershipCleared(succeeded: true), at: time)
  }
}

func writes(_ effects: [Effect], enabled: Bool) -> [UInt64] {
  effects.compactMap {
    if case .setPanelEnabled(let id, _, let actual) = $0, actual == enabled { id } else { nil }
  }
}

@Test func requiresStableSeparatedEvidenceAndDurableJournal() {
  var rig = Rig()
  #expect(writes(rig.observe(at: 0), enabled: false).isEmpty)
  #expect(
    rig.send(.tick, at: 2_000).allSatisfy { if case .saveOwnership = $0 { false } else { true } })
  let effects = rig.observe(at: 2_001)
  #expect(effects.contains { if case .saveOwnership = $0 { true } else { false } })
  #expect(writes(effects, enabled: false).isEmpty)
  #expect(rig.state.ownership == nil)
  let id = rig.state.operation!.id
  // A durable record is not yet permission to write: the helper must lease this operation.
  let journaled = rig.send(.journalSaved(operationID: id, succeeded: true), at: 2_002)
  #expect(writes(journaled, enabled: false).isEmpty)
  #expect(journaled.contains { if case .armProtection = $0 { true } else { false } })
  #expect(rig.state.operation?.phase == .arming)
  #expect(rig.state.ownership?.target == panel)
  #expect(
    writes(rig.send(.protectionArmed(operationID: id, succeeded: true), at: 2_003), enabled: false)
      == [id])
}

@Test func withoutAPairedHelperNothingIsEvenJournaled() {
  var rig = Rig(protected: false)
  rig.observe(at: 0)
  let effects = rig.observe(at: 2_001)
  #expect(effects.allSatisfy { if case .saveOwnership = $0 { false } else { true } })
  #expect(rig.state.operation == nil)
  #expect(Controller.unavailability(rig.state, at: 2_001) == .noRecoveryHelper)
}

@Test func aRefusedLeaseClearsTheRecordAndNeverTouchesTheDisplay() {
  var rig = Rig()
  rig.prepare()
  let id = rig.state.operation!.id
  rig.send(.journalSaved(operationID: id, succeeded: true), at: 2_001)
  let refused = rig.send(.protectionArmed(operationID: id, succeeded: false), at: 2_002)
  #expect(writes(refused, enabled: false).isEmpty)
  #expect(writes(refused, enabled: true).isEmpty)
  #expect(refused.contains(.clearOwnership))
  #expect(rig.state.fault == .protectionUnavailable)
  // Nothing was written, so the record is cleared rather than restored.
  #expect(rig.state.pendingClear)
  rig.cleared(at: 2_003)
  #expect(rig.state.ownership == nil)
}

@Test func anUnansweredLeaseRequestTimesOutWithoutWriting() {
  var rig = Rig()
  rig.prepare()
  let id = rig.state.operation!.id
  rig.send(.journalSaved(operationID: id, succeeded: true), at: 2_001)
  let expired = rig.send(.tick, at: 5_002)
  #expect(writes(expired, enabled: false).isEmpty)
  #expect(rig.state.fault == .protectionUnavailable)
  #expect(rig.state.operation == nil)
  #expect(expired.contains(.clearOwnership))
}

@Test func losingTheHelperWhileOwningRestoresAndStopsDisabling() {
  var rig = Rig()
  rig.disabled()
  let effects = rig.send(.protectionAvailable(false), at: 2_100)
  #expect(writes(effects, enabled: true).count == 1)
  #expect(rig.state.fault == .protectionLost)
  #expect(!rig.state.wantsOff)
}

@Test func aFailedClearKeepsOwnershipAndIsRetriedExplicitly() {
  var rig = Rig()
  rig.disabled()
  rig.send(.keepOn, at: 2_100)
  let restoreID = rig.state.operation!.id
  rig.send(.operationReturned(operationID: restoreID, succeeded: true), at: 2_101)
  rig.observe(environment(), at: 2_102)
  #expect(rig.state.pendingClear)
  rig.send(.ownershipCleared(succeeded: false), at: 2_103)
  // A storage failure must never be reported as released ownership.
  #expect(rig.state.ownership != nil)
  #expect(rig.state.pendingClear)
  #expect(rig.state.fault == .ownershipClearFailed)
  #expect(Controller.unavailability(rig.state, at: 2_104) == .faulted)
  #expect(rig.send(.retry, at: 2_104).contains(.clearOwnership))
  rig.cleared(at: 2_105)
  #expect(rig.state.ownership == nil)
  #expect(!rig.state.pendingClear)
}

@Test(arguments: [Fact.no, .unknown, .conflicting])
func uncertainExternalNeverAuthorizesDisabling(_ fact: Fact) {
  var rig = Rig()
  rig.observe(environment(external: fact), at: 0)
  rig.observe(environment(external: fact), at: 3_000)
  #expect(rig.state.operation == nil)
}

@Test func missingPanelAndUnvalidatedBackendRemainUntouched() {
  var rig = Rig()
  var empty = environment()
  empty.panel = nil
  empty.lid = .absent
  rig.observe(empty, at: 0)
  rig.observe(empty, at: 3_000)
  #expect(rig.state.operation == nil)
  rig.observe(environment(backend: .unknown), at: 4_000)
  rig.observe(environment(backend: .unknown), at: 7_000)
  #expect(rig.state.operation == nil)
}

@Test func unvalidatedMirroredTopologyIsExplicitlyInhibited() {
  var rig = Rig()
  var mirrored = environment()
  mirrored.supportedTopology = .no
  rig.observe(mirrored, at: 0)
  rig.observe(mirrored, at: 2_000)
  #expect(rig.state.operation == nil)
}

// Inspired by the native wake timeline: the external reappeared after System woke.
// Inputs are normalized synthetic facts, not a claim that raw flags validate native transport.
@Test(arguments: [Instant(713), 5_000, 30_000])
func wakeWaitsForExternalEvidenceThenItsOwnStabilityInterval(_ externalDelay: Instant) {
  var rig = Rig()
  rig.observe(at: 0)
  rig.send(.willSleep, at: 10)
  rig.observe(environment(panelState: .unknown, external: .unknown, power: .sleeping), at: 20)
  rig.send(.waking, at: 100)
  rig.observe(environment(external: .unknown), at: 101)
  #expect(rig.state.operation == nil)

  let reappearedAt = 100 + externalDelay
  rig.send(.tick, at: reappearedAt - 1)
  #expect(rig.state.operation == nil)
  rig.observe(at: reappearedAt)
  rig.observe(at: reappearedAt + 1)
  #expect(rig.state.operation == nil)
  rig.observe(at: reappearedAt + 500)
  rig.send(.tick, at: reappearedAt + 1_999)
  #expect(rig.state.operation == nil)
  let effects = rig.observe(at: reappearedAt + 2_000)
  #expect(effects.contains { if case .saveOwnership = $0 { true } else { false } })
  #expect(writes(effects, enabled: false).isEmpty)
  let operation = rig.state.operation!
  rig.send(.journalSaved(operationID: operation.id, succeeded: true), at: reappearedAt + 2_001)
  #expect(
    writes(
      rig.send(
        .protectionArmed(operationID: operation.id, succeeded: true),
        at: reappearedAt + 2_002), enabled: false) == [operation.id])
}

@Test func expiredEvidenceDoesNotCreateABusyTimerLoop() {
  var rig = Rig()
  rig.prepare()
  rig.send(.journalSaved(operationID: rig.state.operation!.id, succeeded: false), at: 2_001)
  let effects = rig.send(.tick, at: 20_000)
  #expect(!effects.contains { if case .wakeAt = $0 { true } else { false } })
}

@Test func disconnectWhileJournalIsBeingWrittenInvalidatesDisable() {
  var rig = Rig()
  rig.prepare()
  let id = rig.state.operation!.id
  rig.observe(environment(external: .no), at: 2_001)
  let effects = rig.send(.journalSaved(operationID: id, succeeded: true), at: 2_002)
  #expect(writes(effects, enabled: false).isEmpty)
  #expect(effects.contains(.clearOwnership))
  #expect(rig.state.pendingClear)
  rig.cleared(at: 2_003)
  #expect(rig.state.ownership == nil)
}

@Test func failedJournalNeverSendsDisplayMutation() {
  var rig = Rig()
  rig.prepare()
  let effects = rig.send(
    .journalSaved(operationID: rig.state.operation!.id, succeeded: false), at: 2_001)
  #expect(writes(effects, enabled: false).isEmpty)
  #expect(rig.state.fault == .journalFailed)
}

@Test func staleJournalAcknowledgementCannotDisable() {
  var rig = Rig()
  rig.prepare()
  let effects = rig.send(
    .journalSaved(operationID: rig.state.operation!.id, succeeded: true), at: 8_000)
  #expect(writes(effects, enabled: false).isEmpty)
  #expect(effects.contains(.clearOwnership))
  rig.cleared(at: 8_001)
  #expect(rig.state.ownership == nil)
}

@Test func lateSuccessAfterUserChangesIntentTriggersRestoration() {
  var rig = Rig()
  rig.prepare()
  let id = rig.state.operation!.id
  rig.send(.journalSaved(operationID: id, succeeded: true), at: 2_001)
  rig.send(.protectionArmed(operationID: id, succeeded: true), at: 2_002)
  #expect(writes(rig.send(.keepOn, at: 2_002), enabled: true).isEmpty)
  let effects = rig.send(.operationReturned(operationID: id, succeeded: true), at: 2_003)
  #expect(writes(effects, enabled: true).count == 1)
  #expect(rig.state.ownership != nil)
  #expect(rig.state.mode == .automaticPaused)
}

@Test func timeoutDoesNotInventCancellationOrPermitConcurrentWriter() {
  var rig = Rig()
  rig.prepare()
  let id = rig.state.operation!.id
  rig.send(.journalSaved(operationID: id, succeeded: true), at: 2_001)
  rig.send(.protectionArmed(operationID: id, succeeded: true), at: 2_002)
  let effects = rig.send(.tick, at: 5_002)
  #expect(effects.contains(.writerUnresponsive(operationID: id)))
  #expect(rig.state.operation?.phase == .stalled)
  #expect(writes(effects, enabled: true).isEmpty)
  #expect(writes(rig.send(.retry, at: 5_003), enabled: true).isEmpty)
  let late = rig.send(.operationReturned(operationID: id, succeeded: false), at: 5_004)
  #expect(writes(late, enabled: true).count == 1)
  #expect(rig.state.ownership != nil)
}

@Test func missingExternalRestoresWithoutDebounce() {
  var rig = Rig()
  rig.disabled()
  let effects = rig.observe(environment(panelState: .disabled, external: .no), at: 2_100)
  #expect(writes(effects, enabled: true).count == 1)
}

@Test func reconnectDoesNotReusePreDisconnectStabilityOrOwnership() {
  var rig = Rig()
  rig.disabled()
  let firstOwner = rig.state.ownership!.operationID
  let restore = rig.observe(environment(panelState: .disabled, external: .no), at: 2_100)
  #expect(writes(restore, enabled: true).count == 1)
  let restoreID = rig.state.operation!.id
  rig.send(.operationReturned(operationID: restoreID, succeeded: true), at: 2_110)
  rig.observe(environment(external: .no), at: 2_120)
  rig.cleared(at: 2_121)
  #expect(rig.state.ownership == nil)
  #expect(rig.state.operation == nil)

  rig.observe(at: 7_570)
  rig.observe(at: 7_571)
  #expect(rig.state.operation == nil)
  rig.observe(at: 8_070)
  rig.send(.tick, at: 9_569)
  #expect(rig.state.operation == nil)
  let prepare = rig.observe(at: 9_570)
  #expect(prepare.contains { if case .saveOwnership = $0 { true } else { false } })
  #expect(writes(prepare, enabled: false).isEmpty)
  let nextOwner = rig.state.operation!.id
  #expect(nextOwner != firstOwner)
  // A stale acknowledgement from the previous ownership cannot advance this operation.
  rig.send(.journalSaved(operationID: firstOwner, succeeded: true), at: 9_571)
  #expect(rig.state.operation?.phase == .journaling)
  rig.send(.journalSaved(operationID: nextOwner, succeeded: true), at: 9_572)
  #expect(
    writes(
      rig.send(.protectionArmed(operationID: firstOwner, succeeded: true), at: 9_573),
      enabled: false
    ).isEmpty)
  #expect(
    writes(
      rig.send(.protectionArmed(operationID: nextOwner, succeeded: true), at: 9_574),
      enabled: false) == [nextOwner])
}

@Test func unchangedEligibleExternalDoesNotToggle() {
  var rig = Rig()
  rig.disabled()
  for time: Int64 in [3_000, 4_000, 6_000] {
    let effects = rig.observe(environment(panelState: .disabled), at: time)
    #expect(writes(effects, enabled: true).isEmpty)
    #expect(writes(effects, enabled: false).isEmpty)
    #expect(rig.state.operation == nil)
  }
}

@Test func staleEvidenceTriggersRestorationEvenWithoutNotifications() {
  var rig = Rig()
  rig.disabled()
  let effects = rig.send(.tick, at: 7_021)
  #expect(writes(effects, enabled: true).count == 1)
}

@Test func manualRequestDoesNotSurviveSleep() {
  var rig = Rig(mode: .manual)
  rig.send(.manualOff, at: 0)
  rig.disabled()
  let effects = rig.send(.willSleep, at: 2_100)
  #expect(!rig.state.manualRequest)
  #expect(writes(effects, enabled: true).count == 1)
  #expect(!rig.state.wantsOff)
}

@Test func sleepingPanelDoesNotFailVisibilityVerification() {
  var rig = Rig()
  rig.disabled()
  rig.send(.willSleep, at: 2_100)
  let id = rig.state.operation!.id
  rig.send(.operationReturned(operationID: id, succeeded: true), at: 2_101)
  rig.observe(environment(panelState: .unknown, power: .sleeping, lid: .closed), at: 2_102)
  rig.send(.tick, at: 10_000)
  #expect(rig.state.fault == nil)
  #expect(rig.state.ownership != nil)
  rig.observe(environment(panelState: .enabled), at: 10_100)
  rig.cleared(at: 10_101)
  #expect(rig.state.ownership == nil)
  #expect(rig.state.fault == nil)
}

@Test func successfulCallRequiresFreshPostReturnVerification() {
  var rig = Rig()
  rig.prepare()
  let id = rig.state.operation!.id
  rig.send(.journalSaved(operationID: id, succeeded: true), at: 2_001)
  rig.send(.protectionArmed(operationID: id, succeeded: true), at: 2_002)
  rig.observe(environment(panelState: .disabled), at: 2_002)
  rig.send(.operationReturned(operationID: id, succeeded: true), at: 2_003)
  #expect(rig.state.operation?.phase == .verifying)
  rig.observe(environment(panelState: .disabled), at: 2_004)
  #expect(rig.state.operation == nil)
}

@Test func restorationErrorsAreBoundedAndOwnershipSurvives() {
  var rig = Rig()
  rig.disabled()
  rig.send(.keepOn, at: 2_100)
  rig.send(.operationReturned(operationID: rig.state.operation!.id, succeeded: false), at: 2_101)
  #expect(rig.state.operation == nil)
  rig.send(.tick, at: 2_601)
  #expect(rig.state.restoreAttempts == 2)
  rig.send(.operationReturned(operationID: rig.state.operation!.id, succeeded: false), at: 2_602)
  rig.send(.tick, at: 4_602)
  #expect(rig.state.restoreAttempts == 3)
  rig.send(.operationReturned(operationID: rig.state.operation!.id, succeeded: false), at: 4_603)
  #expect(rig.state.fault == .recoveryExhausted)
  #expect(writes(rig.send(.tick, at: 10_000), enabled: true).isEmpty)
  #expect(rig.state.ownership != nil)
}

@Test func oldOrFutureObservationCannotReplaceNewEvidence() {
  var rig = Rig()
  rig.prepare()
  let original = rig.state.observation
  rig.send(
    .observed(.init(sequence: 1, sampledAt: 1_000, environment: environment(external: .no))),
    at: 2_001)
  #expect(rig.state.observation == original)
  rig.send(.observed(.init(sequence: 100, sampledAt: 9_000, environment: environment())), at: 2_002)
  #expect(rig.state.observation == original)
}

@Test func identityChangeNeverEnablesTheReplacementDisplay() {
  var rig = Rig()
  rig.disabled()
  var other = environment(panelState: .disabled, external: .no)
  other.panel?.displayID = 99
  let effects = rig.observe(other, at: 2_100)
  #expect(rig.state.fault == .identityChanged)
  #expect(writes(effects, enabled: true).isEmpty)
  #expect(rig.state.ownership?.target.displayID == 1)
}

@Test func unexpectedRestorationPausesRatherThanFighting() {
  var rig = Rig()
  rig.disabled()
  rig.observe(environment(), at: 2_100)
  #expect(rig.state.fault == .conflictingController)
  rig.cleared(at: 2_101)
  #expect(rig.state.ownership == nil)
  #expect(writes(rig.observe(environment(), at: 5_000), enabled: false).isEmpty)
}

@Test func quitWaitsForRestorationVerification() {
  var rig = Rig()
  rig.disabled()
  #expect(!rig.send(.quit, at: 2_100).contains(.exitReady))
  let id = rig.state.operation!.id
  #expect(
    !rig.send(.operationReturned(operationID: id, succeeded: true), at: 2_101).contains(.exitReady))
  // Verified restoration is not enough: quit also waits for the record to be gone.
  #expect(!rig.observe(environment(), at: 2_102).contains(.exitReady))
  #expect(rig.cleared(at: 2_103).contains(.exitReady))
}

@Test func replayPreservesExactDecisions() throws {
  var rig = Rig()
  rig.disabled()
  rig.send(.keepOn, at: 2_100)
  let encoded = try JSONEncoder().encode(rig.trace)
  let decoded = try JSONDecoder().decode(ReplayTrace.self, from: encoded)
  #expect(try decoded.replay().last?.state == rig.state)
  #expect(try decoded.replay() == decoded.replay())
}

@Test func pausedPreferenceSurvivesSerialization() throws {
  var rig = Rig()
  rig.send(.keepOn, at: 0)
  let restored = try JSONDecoder().decode(
    ControllerState.self, from: JSONEncoder().encode(rig.state))
  #expect(restored.mode == .automaticPaused)
  #expect(!restored.wantsOff)
}

@Test func generatedAdversarialTracesRespectMutationPreconditions() {
  // Fixed seeds make failures reproducible. This checks effects against independent state properties.
  for seed in 1...80 {
    var random = UInt64(seed)
    func next() -> UInt64 {
      random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return random
    }
    var rig = Rig()
    var time: Int64 = 0
    for _ in 0..<250 {
      time += Int64(next() % 750)
      let before = rig.state
      let effects: [Effect]
      switch next() % 13 {
      case 0: effects = rig.send(.keepOn, at: time)
      case 1: effects = rig.send(.selectMode(.automatic), at: time)
      case 2: effects = rig.send(.willSleep, at: time)
      case 3: effects = rig.send(.tick, at: time)
      case 4:
        effects = rig.send(
          .journalSaved(operationID: before.operation?.id ?? 999, succeeded: next() % 4 != 0),
          at: time)
      case 5:
        effects = rig.send(
          .operationReturned(operationID: before.operation?.id ?? 999, succeeded: next() % 3 != 0),
          at: time)
      case 6:
        effects = rig.send(
          .protectionArmed(operationID: before.operation?.id ?? 999, succeeded: next() % 4 != 0),
          at: time)
      case 7: effects = rig.send(.ownershipCleared(succeeded: next() % 3 != 0), at: time)
      case 8: effects = rig.send(.protectionAvailable(next() % 5 != 0), at: time)
      case 9:
        effects = rig.send(.operationRefused(operationID: before.operation?.id ?? 999), at: time)
      default:
        let external: Fact = next() % 4 == 0 ? .unknown : .yes
        let panelState: PanelState =
          before.ownership == nil ? .enabled : (next() % 4 == 0 ? .unknown : .disabled)
        effects = rig.observe(environment(panelState: panelState, external: external), at: time)
      }
      let mutations = effects.filter { if case .setPanelEnabled = $0 { true } else { false } }
      #expect(mutations.count <= 1)
      for effect in mutations {
        guard case .setPanelEnabled(let id, let target, let enabled) = effect else { continue }
        #expect(target == panel)
        #expect(rig.state.ownership?.target == target)
        #expect(rig.state.operation?.id == id)
        #expect(rig.state.operation?.phase == .submitted)
        if !enabled {
          // A disable is only ever issued out of an acknowledged, operation-bound lease.
          #expect(before.operation?.phase == .arming)
          #expect(rig.state.protectionAvailable)
          #expect(!rig.state.pendingClear)
          #expect(rig.state.fault == nil)
          #expect(rig.state.wantsOff)
          #expect(rig.state.observation?.environment.nativeExternalAvailable == .yes)
          #expect(rig.state.observation?.environment.lid == .open)
          #expect(rig.state.observation?.environment.backendValidated == .yes)
          #expect(time - rig.state.observation!.sampledAt <= rig.state.policy.evidenceLifetime)
        }
      }
    }
  }
}
