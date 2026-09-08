import LidlessCore
import Testing

@testable import LidlessPlatform

private func snapshot() -> PlatformReading {
  .init(
    osVersion: "test", monotonicMilliseconds: 0,
    displays: [
      .init(
        id: 1, uuid: "panel", uuidResolvedID: 1, builtIn: true, active: true,
        online: true, asleep: false, mirrored: false, width: 100, height: 100,
        originX: 0, originY: 0, modeAvailable: true)
    ], lid: .open, bootID: "boot", loginID: 1, foregroundSession: .yes,
    privateSymbol: "available", limitations: [])
}

@Test func rawFlagsNeverGrantProductionAuthority() {
  var reading = snapshot()
  reading.backendValidated = true
  let environment = ControllerObservation.environment(reading, power: .awake)
  #expect(environment.panelState == .enabled)
  #expect(environment.backendValidated == .unknown)
  #expect(environment.nativeExternalAvailable == .unknown)
  #expect(environment.supportedTopology == .unknown)
}

@Test func missingOrMirroredPanelIsNeverInferredDisabled() {
  var reading = snapshot()
  reading.displays[0].mirrored = true
  reading.displays[0].active = false
  var environment = ControllerObservation.environment(reading, power: .awake)
  #expect(environment.panelState == .unknown)
  #expect(environment.supportedTopology == .no)
  reading.displays = []
  environment = ControllerObservation.environment(reading, power: .awake)
  #expect(environment.panel == nil)
  #expect(environment.panelState == .unknown)
  #expect(environment.nativeExternalAvailable == .unknown)
}

@Test func enumerationFailureCannotReusePartialInventory() {
  var reading = snapshot()
  reading.enumerationError = 1
  let environment = ControllerObservation.environment(reading, power: .waking)
  #expect(environment.panel == nil)
  #expect(environment.panelState == .unknown)
  #expect(environment.power == .waking)
}

@Test func liveNormalizationKeepsAutomaticControllerInhibited() {
  var shadow = ShadowController()
  shadow.receive(.selectMode(.automatic), at: 0)
  for instant in stride(from: Int64(0), through: 10_000, by: 500) {
    shadow.observe(ControllerObservation.environment(snapshot(), power: .awake), at: instant)
    shadow.tick(at: instant)
  }
  #expect(shadow.state.operation == nil)
  #expect(shadow.state.ownership == nil)
  #expect(shadow.observationCount == 21)
  // The preferences request is deliberately rejected too: shadow mode has no storage executor.
  #expect(shadow.rejectedEffectCount == 1)
}
