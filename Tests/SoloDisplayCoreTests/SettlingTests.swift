import Testing
@testable import SoloDisplayCore

// Settling after macOS reports a display reconfiguration. Without a report that explains the
// arrangement, the full `stableFor` interval in ControllerTests still applies.

@Test func aReportedReconfigurationSettlesOnceMacOSGoesQuiet() {
  var rig = Rig()
  rig.send(.displayReconfigured(inProgress: true), at: 0)
  rig.send(.displayReconfigured(inProgress: false), at: 10)
  // The reading that can settle it is requested exactly when it could, not on the next refresh.
  #expect(rig.observe(at: 20).contains(.observeAt(520)))
  #expect(Controller.unavailability(rig.state, at: 20) == .settling)
  #expect(startsTurningOff(rig.observe(at: 520)))
}

@Test func aReconfigurationThatNeverFinishesWaitsForTheCap() {
  var rig = Rig()
  rig.send(.displayReconfigured(inProgress: true), at: 0)
  rig.observe(at: 10)
  #expect(rig.observe(at: 600).contains(.observeAt(5010)))
  // The plain two second interval has passed, but macOS never said it was done.
  #expect(!startsTurningOff(rig.observe(at: 2500)))
  #expect(startsTurningOff(rig.observe(at: 5010)))
}

@Test func anotherReportRestartsTheQuietPeriod() {
  var rig = Rig()
  rig.send(.displayReconfigured(inProgress: false), at: 0)
  rig.observe(at: 10)
  rig.send(.displayReconfigured(inProgress: false), at: 400)
  #expect(!startsTurningOff(rig.observe(at: 600)))
  #expect(startsTurningOff(rig.observe(at: 900)))
}

@Test func anOldReportDoesNotShortenTheFullInterval() {
  var rig = Rig()
  rig.send(.displayReconfigured(inProgress: false), at: 0)
  // Nothing macOS reported explains this arrangement, so the full interval applies.
  #expect(rig.observe(at: 10000).contains(.observeAt(12000)))
  #expect(!startsTurningOff(rig.observe(at: 10600)))
  #expect(startsTurningOff(rig.observe(at: 12000)))
}

@Test func ourOwnReconfigurationDoesNotUndoATurnOff() {
  // Turning the screen off makes macOS report a reconfiguration. That must not read as a
  // setup that is still settling and turn the screen straight back on.
  var rig = Rig()
  rig.off()
  let effects = rig.send(.displayReconfigured(inProgress: false), at: 2030)
  #expect(workers(effects, .enable) == 0)
  #expect(workers(rig.observe(environment(panelState: .disabled), at: 2040), .enable) == 0)
}
