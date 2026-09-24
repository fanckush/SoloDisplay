import SoloDisplayCore
import Testing
@testable import SoloDisplayPlatform

private let builtIn = PanelTarget(
  displayID: 1, displayUUID: "internal", bootID: "test-boot", loginID: 1
)
private let external = PanelTarget(
  displayID: 2, displayUUID: "unverified-monitor", bootID: "test-boot", loginID: 1,
  kind: .external, controller: "dispext0"
)

private struct Issue15Rig {
  var state: ControllerState
  var sequence: UInt64 = 0

  init(mode: Mode = .automatic) {
    state = .init(mode: mode)
  }

  @discardableResult mutating func send(_ event: Event, at time: Instant) -> [Effect] {
    let transition = Controller.reduce(state, event, at: time)
    state = transition.state
    return transition.effects
  }

  @discardableResult mutating func observe(at time: Instant, suppressed: Bool = false) -> [Effect] {
    sequence += 1
    return send(.observed(.init(sequence: sequence, sampledAt: time, environment: .init(
      panel: builtIn, panelState: .enabled, power: .awake, lid: .open,
      foregroundSession: .yes, nativeExternalAvailable: suppressed ? .no : .yes,
      supportedTopology: .yes,
      externals: [.init(target: external, suppressible: !suppressed, suppressed: suppressed)],
      visibleDisplays: suppressed ? 1 : 2
    ))), at: time)
  }

  @discardableResult mutating func answer(_ current: UInt16?, at time: Instant) -> [Effect] {
    let evidence = [InputSourceEvidence(
      controller: "dispext0", target: external,
      reply: current.map { DDCValue(current: $0, maximum: 0xFFFF) }
    )]
    return send(.inputSourcesRead(
      InputSourceClassifier.showingThisMac(evidence),
      monitors: InputSourceClassifier.perMonitor(evidence), sampledAt: time
    ), at: time)
  }

  mutating func suppress() -> [Effect] {
    observe(at: 0)
    answer(0x0111, at: 100)
    observe(at: 2000)
    answer(0x0111, at: 2100)
    send(.tick, at: 2200)
    send(.suppressionRecorded([external], succeeded: true), at: 2300)
    return send(.guardianReady, at: 2400)
  }
}

struct Issue15InvestigationTests {
  /// Synthetic bytes, NOT captured from the Samsung in issue #15.
  @Test(arguments: [Mode.automatic, .automaticPaused, .manual])
  func unverifiedReservedByteCanAuthorizeExternalDisable(_ mode: Mode) {
    var rig = Issue15Rig(mode: mode)
    #expect(rig.suppress().contains(.runWorker(.disable, external)))
  }

  @Test func changingUnverifiedBytesCanRequestOffOnOff() {
    var rig = Issue15Rig()
    #expect(rig.suppress().contains(.runWorker(.disable, external)))
    rig.send(.workerFinished(.done), at: 2500)
    rig.observe(at: 2600, suppressed: true)
    #expect(rig.answer(0x1111, at: 3000).contains(.runWorker(.enable, external)))
    rig.send(.workerFinished(.done), at: 3100)
    rig.observe(at: 3200)
    rig.send(.suppressionRecorded([], succeeded: true), at: 3300)
    rig.answer(0x0111, at: 3400)
    rig.observe(at: 34000)
    rig.send(.tick, at: 34100)
    rig.send(.suppressionRecorded([external], succeeded: true), at: 34200)
    #expect(rig.send(.guardianReady, at: 34300).contains(.runWorker(.disable, external)))
  }

  @Test func unansweredPollsShouldNotPreventTheSilenceRecovery() {
    var rig = Issue15Rig()
    #expect(rig.suppress().contains(.runWorker(.disable, external)))
    rig.send(.workerFinished(.done), at: 2500)
    rig.observe(at: 2600, suppressed: true)
    var requestedRestore = false
    for time in stride(from: Instant(10000), through: 400_000, by: 10000) {
      requestedRestore = requestedRestore || rig.answer(nil, at: time).contains(.runWorker(
        .enable,
        external
      ))
    }
    #expect(
      requestedRestore,
      "Every nil reply refreshes lastAnswered, defeating the 300-second recovery timeout"
    )
  }
}
