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

private func external(
  id: UInt32 = 5, transport: DisplayTransport, mirrored: Bool = false, source: UInt32? = nil
) -> DisplayReading {
  .init(
    id: id, uuid: "external-\(id)", uuidResolvedID: id, builtIn: false, active: true,
    online: true, asleep: false, mirrored: mirrored, mirrorSourceID: source, width: 1920,
    height: 1080, originX: 0, originY: -1080, modeAvailable: true, transport: transport.rawValue)
}

@Test func aFoundPrivateSymbolIsNotAValidatedBackend() {
  let reading = snapshot()
  #expect(reading.privateSymbol != nil)
  // The symbol resolves, but nothing has established that the call does what it claims.
  #expect(ControllerObservation.environment(reading, power: .awake).backendValidated == .unknown)
  var validated = reading
  validated.backendValidated = true
  #expect(ControllerObservation.environment(validated, power: .awake).backendValidated == .yes)
}

@Test func onlyPositivelyClassifiedNativeExternalsCount() {
  var reading = snapshot()
  // No external at all is a definite no, not an unknown.
  #expect(ControllerObservation.environment(reading, power: .awake).nativeExternalAvailable == .no)

  reading.displays.append(external(transport: .unclassified))
  #expect(
    ControllerObservation.environment(reading, power: .awake).nativeExternalAvailable == .unknown)

  reading.displays[1] = external(transport: .virtual)
  #expect(ControllerObservation.environment(reading, power: .awake).nativeExternalAvailable == .no)

  reading.displays[1] = external(transport: .native)
  #expect(ControllerObservation.environment(reading, power: .awake).nativeExternalAvailable == .yes)

  // One unclassified display among natives is enough to withhold authorization.
  reading.displays.append(external(id: 6, transport: .unclassified))
  #expect(
    ControllerObservation.environment(reading, power: .awake).nativeExternalAvailable == .unknown)
}

@Test func anInternalFollowerOfOnePresentSourceIsASupportedMirror() {
  var reading = snapshot()
  reading.displays[0].mirrored = true
  reading.displays[0].active = false
  reading.displays[0].mirrorSourceID = 5
  reading.displays.append(external(transport: .native, mirrored: true))
  let environment = ControllerObservation.environment(reading, power: .awake)
  #expect(environment.supportedTopology == .yes)
  // An inactive follower is presence, not suppression and not a failed restoration.
  #expect(environment.panelState == .enabled)
}

@Test func anInternalMirrorSourceOrAGhostSourceStaysUnsupported() {
  var reading = snapshot()
  reading.displays[0].mirrored = true
  reading.displays[0].mirrorSourceID = nil
  reading.displays.append(external(transport: .native, mirrored: true, source: 1))
  // The internal panel is the source here, which is a topology no experiment has covered.
  #expect(ControllerObservation.environment(reading, power: .awake).supportedTopology == .no)

  var ghost = snapshot()
  ghost.displays[0].mirrored = true
  ghost.displays[0].mirrorSourceID = 99
  ghost.displays.append(external(transport: .native, mirrored: true))
  #expect(ControllerObservation.environment(ghost, power: .awake).supportedTopology == .no)
}

@Test func absenceBecomesSuppressionOnlyWithOwnershipAndAReturnedDisable() {
  var reading = snapshot()
  reading.displays = [external(transport: .native)]
  let target = PanelTarget(displayID: 1, displayUUID: "panel", bootID: "boot", loginID: 1)
  #expect(ControllerObservation.environment(reading, power: .awake).panelState == .unknown)

  let unreturned = OwnedPanelContext(target: target, disableReturned: false)
  #expect(
    ControllerObservation.environment(reading, power: .awake, owned: unreturned).panelState
      == .unknown)

  let returned = OwnedPanelContext(target: target, disableReturned: true)
  #expect(
    ControllerObservation.environment(reading, power: .awake, owned: returned).panelState
      == .disabled)

  // Ownership recorded in another boot explains nothing about this one.
  let foreign = OwnedPanelContext(
    target: .init(displayID: 1, displayUUID: "panel", bootID: "other", loginID: 1),
    disableReturned: true)
  #expect(
    ControllerObservation.environment(reading, power: .awake, owned: foreign).panelState
      == .unknown)
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

@Test func displaySleepDoesNotWithdrawAnOtherwiseEligibleExternal() {
  var reading = snapshot()
  reading.displays[0].mirrored = true
  reading.displays[0].active = false
  reading.displays[0].mirrorSourceID = 5
  reading.displays.append(external(transport: .native, mirrored: true))
  #expect(ControllerObservation.environment(reading, power: .awake).nativeExternalAvailable == .yes)

  // Screen sleep leaves the monitor connected. Putting a suppressed panel back would only
  // produce a pointless flash on the next wake.
  reading.displays[1].asleep = true
  reading.displays[1].active = false
  #expect(ControllerObservation.environment(reading, power: .awake).nativeExternalAvailable == .yes)

  // An external that is actually gone is a different matter.
  reading.displays.removeLast()
  #expect(ControllerObservation.environment(reading, power: .awake).nativeExternalAvailable == .no)
}
