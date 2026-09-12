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
  let settled = rig.observe(at: 520)
  #expect(settled.contains {
    if case .saveOwnership = $0 {
      true
    } else {
      false
    }
  })
  #expect(writes(settled, enabled: false).isEmpty)
}

@Test func aReconfigurationThatNeverFinishesWaitsForTheCap() {
  var rig = Rig()
  rig.send(.displayReconfigured(inProgress: true), at: 0)
  rig.observe(at: 10)
  #expect(rig.observe(at: 600).contains(.observeAt(5010)))
  // The plain two second interval has passed, but macOS never said it was done.
  rig.observe(at: 2500)
  #expect(rig.state.operation == nil)
  rig.observe(at: 5010)
  #expect(rig.state.operation?.phase == .journaling)
}

@Test func anotherReportRestartsTheQuietPeriod() {
  var rig = Rig()
  rig.send(.displayReconfigured(inProgress: false), at: 0)
  rig.observe(at: 10)
  rig.send(.displayReconfigured(inProgress: false), at: 400)
  rig.observe(at: 600)
  #expect(rig.state.operation == nil)
  rig.observe(at: 900)
  #expect(rig.state.operation?.phase == .journaling)
}

@Test func anOldReportDoesNotShortenTheFullInterval() {
  var rig = Rig()
  rig.send(.displayReconfigured(inProgress: false), at: 0)
  // Nothing macOS reported explains this arrangement, so the full interval applies.
  #expect(rig.observe(at: 10000).contains(.observeAt(12000)))
  rig.observe(at: 10600)
  #expect(rig.state.operation == nil)
  rig.observe(at: 12000)
  #expect(rig.state.operation?.phase == .journaling)
}
