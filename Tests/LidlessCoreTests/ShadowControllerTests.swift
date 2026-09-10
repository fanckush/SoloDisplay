import Testing
@testable import LidlessCore

@Test func shadowCannotAcknowledgeItsOwnJournalOrExecuteEffects() {
  var shadow = ShadowController()
  shadow.receive(.selectMode(.automatic), at: 0)
  shadow.receive(.protectionAvailable(true), at: 0)
  shadow.observe(environment(), at: 0)
  shadow.observe(environment(), at: 2000)
  // A shadow executor cannot acknowledge preference persistence either.
  #expect(shadow.state.operation == nil)
  #expect(shadow.state.ownership == nil)
  #expect(shadow.rejectedEffectCount == 1)
  shadow.tick(at: 6000)
  #expect(shadow.state.ownership == nil)
}

@Test func shadowRejectsOldSamplesAndInvalidatesSleepIntent() {
  var shadow = ShadowController()
  shadow.observe(environment(), at: 100)
  shadow.observe(environment(), at: 99)
  #expect(shadow.observationCount == 1)
  shadow.receive(.manualOff, at: 101)
  shadow.receive(.willSleep, at: 102)
  #expect(!shadow.state.manualRequest)
  #expect(shadow.state.observation?.environment.power == .sleeping)
}
