import Testing
@testable import SoloDisplayCore

/// A monitor with several inputs can be switched to another machine while this Mac still sees it:
/// the link stays up, so macOS enumerates it and nothing in a display reading says it is not on
/// screen. Asking the monitor itself is the only evidence, and it is only ever a veto.
struct InputSourceControllerTests {
  @Test func nothingIsTurnedOffBeforeTheMonitorsHaveBeenAsked() {
    var rig = Rig()
    rig.answersMonitors = false
    // The monitors are asked as soon as there is something to ask, well before settling ends.
    #expect(rig.observe(at: 0).contains(.readInputSources))
    #expect(!startsTurningOff(rig.observe(at: 2000)))
    #expect(Controller.unavailability(rig.state, at: 2000) == .settling)
  }

  @Test func aMonitorShowingAnotherMachineIsNeverTurnedOffFor() {
    var rig = Rig()
    rig.monitorAnswer = .no
    rig.observe(at: 0)
    #expect(!startsTurningOff(rig.observe(at: 2000)))
    #expect(!startsTurningOff(rig.send(.tick, at: 4000)))
    #expect(Controller.unavailability(rig.state, at: 4000) == .monitorShowsAnotherMachine)
  }

  /// One answer withholds, because withholding changes nothing and the next answer undoes it.
  @Test func oneAnswerIsEnoughToWithholdButNotToActOnIt() {
    var rig = Rig()
    rig.monitorAnswer = .no
    rig.observe(at: 0)
    // One answer only puts it forward, and that alone is already enough to withhold.
    #expect(rig.state.inputSources == .unknown)
    #expect(rig.state.inputSourcesPending == .no)
    #expect(rig.state.inputRefusal)
    #expect(!startsTurningOff(rig.observe(at: 2000)))
  }

  @Test func aMonitorThatSwitchesAwayBringsTheScreenBack() {
    var rig = Rig()
    rig.off()
    rig.monitorAnswer = .no
    // The first answer is not enough to put the screen back: that is a change, so it repeats.
    #expect(workers(rig.send(.tick, at: 12021), .enable) == 0)
    #expect(workers(rig.send(.tick, at: 13100), .enable) == 1)
    #expect(Controller.unavailability(rig.state, at: 13100) == .monitorShowsAnotherMachine)
  }

  /// Seen on hardware on 2026-09-19: the screen came back, went off, came back, about once a
  /// second. Putting the panel on is itself a reconfiguration, so a reconfiguration must not be
  /// read as a reason to forget what the monitors just said.
  @Test func restoringTheScreenDoesNotThrowAwayTheReasonItWasRestored() {
    var rig = Rig()
    rig.off()
    rig.monitorAnswer = .no
    rig.send(.tick, at: 12021)
    #expect(workers(rig.send(.tick, at: 13100), .enable) == 1)

    // What macOS reports once the panel is back, which is our own doing.
    rig.send(.displayReconfigured(inProgress: false), at: 13200)
    rig.observe(at: 13300)
    #expect(rig.state.inputRefusal)
    #expect(!startsTurningOff(rig.observe(at: 15400)))
    #expect(!startsTurningOff(rig.send(.tick, at: 20000)))
  }

  @Test func oneMissingAnswerDoesNotCancelARefusal() {
    var rig = Rig()
    rig.off()
    rig.monitorAnswer = .no
    rig.send(.tick, at: 12021)
    rig.send(.tick, at: 13100)
    #expect(rig.state.inputSources == .no)
    // A monitor showing another machine may stop answering altogether. Silence is not a denial.
    rig.monitorAnswer = .unknown
    rig.send(.tick, at: 23200)
    rig.send(.tick, at: 33300)
    #expect(rig.state.inputSources == .no)
  }

  @Test func onlyAPositiveAnswerLiftsARefusal() {
    var rig = Rig()
    rig.off()
    rig.monitorAnswer = .no
    rig.send(.tick, at: 12021)
    rig.send(.tick, at: 13100)
    rig.monitorAnswer = .yes
    rig.send(.tick, at: 23200)
    #expect(rig.state.inputSources == .no)
    rig.send(.tick, at: 24300)
    #expect(rig.state.inputSources == .yes)
  }

  @Test func aDisplayChangeHasToBeAskedAgainButKeepsTheAnswer() {
    var rig = Rig()
    rig.monitorAnswer = .no
    rig.observe(at: 0)
    rig.observe(at: 2000)
    #expect(rig.state.inputRefusal)

    rig.answersMonitors = false
    rig.send(.displayReconfigured(inProgress: false), at: 3000)
    // The arrangement has to be asked again before anything is turned off.
    #expect(rig.state.inputSourcesAskedAt == nil)
    #expect(!startsTurningOff(rig.observe(at: 3100)))
    // The refusal stands meanwhile, because keeping the laptop screen on costs nothing and a
    // reconfiguration is also what our own panel change looks like.
    #expect(rig.state.inputRefusal)

    // A monitor that now says it is showing this Mac lifts it, once it has said so twice.
    rig.send(.inputSourcesRead(.yes, sampledAt: 13200), at: 13200)
    #expect(rig.state.inputRefusal)
    rig.send(.inputSourcesRead(.yes, sampledAt: 14300), at: 14300)
    #expect(!rig.state.inputRefusal)
  }

  @Test func theMonitorsAreAskedAgainWhileTheScreenIsOff() {
    var rig = Rig()
    rig.off()
    rig.answersMonitors = false
    #expect(!rig.send(.tick, at: 7000).contains(.readInputSources))
    #expect(rig.send(.tick, at: 12021).contains(.readInputSources))
  }

  @Test func theMonitorsAreNotAskedWhenNothingCouldComeOfIt() {
    var paused = Rig(mode: .automaticPaused)
    paused.answersMonitors = false
    #expect(!paused.observe(at: 0).contains(.readInputSources))

    var noMonitor = Rig()
    noMonitor.answersMonitors = false
    #expect(!noMonitor.observe(environment(external: .no), at: 0).contains(.readInputSources))

    var closed = Rig()
    closed.answersMonitors = false
    #expect(!closed.observe(environment(lid: .closed), at: 0).contains(.readInputSources))
  }

  @Test func anAskThatNeverAnswersStopsHoldingTheDecision() {
    var rig = Rig()
    rig.answersMonitors = false
    #expect(rig.observe(at: 0).contains(.readInputSources))
    #expect(!startsTurningOff(rig.observe(at: 2000)))
    // A monitor that never comes back must not hold the screen on for ever: what it would have
    // said is nothing, and nothing is what a Mac without DDC has always had.
    #expect(startsTurningOff(rig.send(.tick, at: 5000)))
  }

  @Test func aLateAnswerFromAnAbandonedAskIsIgnored() {
    var rig = Rig()
    rig.answersMonitors = false
    rig.observe(at: 0)
    // An answer given up on can still arrive, and a newer one may already have replaced it.
    rig.send(.inputSourcesRead(.yes, sampledAt: 3000), at: 3000)
    rig.send(.inputSourcesRead(.no, sampledAt: 2000), at: 3001)
    #expect(!rig.state.inputRefusal)
    rig.send(.inputSourcesRead(.no, sampledAt: 3500), at: 3501)
    #expect(rig.state.inputRefusal)
  }
}
