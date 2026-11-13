import Testing
@testable import SoloDisplayCore

private let dell = PanelTarget(
  displayID: 4, displayUUID: "dell", bootID: "boot-1", loginID: 42,
  kind: .external, controller: "dispext0"
)

private func withMonitor(
  _ environment: Environment = environment(), suppressible: Bool = true,
  suppressed: [PanelTarget] = [], visible: Int = 2
) -> Environment {
  var value = environment
  // A monitor is either in the inventory or turned off, never both at once.
  value.externals = suppressed.isEmpty
    ? [.init(target: dell, suppressible: suppressible, suppressed: false)]
    : suppressed.map { .init(target: $0, suppressible: false, suppressed: true) }
  value.visibleDisplays = visible
  return value
}

/// One monitor answering, for a rig that otherwise answers for the arrangement as a whole.
private func answers(_ shown: ShownSource, at time: Instant) -> Event {
  .inputSourcesRead(
    shown == .thisMac ? .yes : (shown == .otherMachine ? .no : .unknown),
    monitors: [.init(controller: "dispext0", target: dell, shown: shown)], sampledAt: time
  )
}

/// A monitor showing another machine is a desktop nobody can see. Turning it off is a change,
/// so it takes the monitor's own word twice, and only while another screen is left.
struct MonitorSuppressionTests {
  private func settled(_ rig: inout Rig, shown: ShownSource, from: Instant = 0) {
    rig.answersMonitors = false
    rig.observe(withMonitor(), at: from)
    rig.observe(withMonitor(), at: from + 2000)
    rig.send(answers(shown, at: from + 2100), at: from + 2100)
  }

  @Test func aMonitorShowingAnotherMachineIsTurnedOffAfterItSaysSoTwice() {
    var rig = Rig(mode: .automaticPaused)
    settled(&rig, shown: .otherMachine)
    // One answer is not enough: this turns a screen off.
    #expect(!rig.state.suppressed.contains(dell))
    let second = rig.send(answers(.otherMachine, at: 3200), at: 3200)
    #expect(rig.state.suppressed == [dell])
    // Nothing is off before the record names it and the guardian has been told.
    #expect(workers(second, .disable) == 0)
    #expect(rig.send(.tick, at: 3250).contains(.recordSuppression([dell])))

    let recorded = rig.send(.suppressionRecorded([dell], succeeded: true), at: 3300)
    #expect(recorded.contains(.spawnGuardian([dell])))
    let ready = rig.send(.guardianReady, at: 3400)
    #expect(ready.contains(.runWorker(.disable, dell)))
  }

  @Test func aMonitorThatCannotAnswerIsNeverTouched() {
    var rig = Rig(mode: .automaticPaused)
    settled(&rig, shown: .unknown)
    let later = rig.send(answers(.unknown, at: 3200), at: 3200)
    #expect(later.isEmpty || !later.contains(.recordSuppression([dell])))
    #expect(rig.state.suppressed.isEmpty)
  }

  @Test func aMonitorShowingThisMacIsNeverTurnedOff() {
    var rig = Rig(mode: .automaticPaused)
    settled(&rig, shown: .thisMac)
    rig.send(answers(.thisMac, at: 3200), at: 3200)
    #expect(rig.state.suppressed.isEmpty)
  }

  /// The laptop screen must never be the thing that goes dark, and a monitor is only ever turned
  /// off while something else is left to look at.
  @Test func theLastScreenIsNeverTurnedOff() {
    var rig = Rig(mode: .automaticPaused)
    rig.answersMonitors = false
    rig.observe(withMonitor(visible: 1), at: 0)
    rig.observe(withMonitor(visible: 1), at: 2000)
    rig.send(answers(.otherMachine, at: 2100), at: 2100)
    let second = rig.send(answers(.otherMachine, at: 3200), at: 3200)
    #expect(!second.contains(.recordSuppression([dell])))
  }

  /// A monitor the reading says cannot be turned off, such as one that is itself following
  /// another screen, is left alone however plainly it says it is showing something else.
  @Test func aMonitorTheArrangementProtectsIsLeftAlone() {
    var rig = Rig(mode: .automaticPaused)
    rig.answersMonitors = false
    rig.observe(withMonitor(suppressible: false), at: 0)
    rig.observe(withMonitor(suppressible: false), at: 2000)
    rig.send(answers(.otherMachine, at: 2100), at: 2100)
    let second = rig.send(answers(.otherMachine, at: 3200), at: 3200)
    #expect(!second.contains(.recordSuppression([dell])))
  }

  /// Turning a monitor back on is always safe, so it happens on much weaker evidence than
  /// turning one off, and it is tried before anything else.
  @Test func aMonitorComesBackAsSoonAsItSaysItIsShowingThisMac() {
    var rig = Rig(mode: .automaticPaused)
    rig.answersMonitors = false
    rig.state.suppressed = [dell]
    // Nothing is ever off that the record does not already name.
    rig.state.recordedSuppression = [dell]
    rig.state.guardian = .ready
    let back = rig.observe(withMonitor(suppressed: [dell]), at: 0)
    #expect(workers(back, .enable) == 0)
    let said = rig.send(answers(.thisMac, at: 100), at: 100)
    #expect(said.contains(.runWorker(.enable, dell)))
  }

  /// Seen on hardware on 2026-09-20: the Dell went off and came back 3 ms later. Leaving exactly
  /// one screen is what turning a monitor off is for, so one screen must not read as danger.
  @Test func aMonitorThatWasJustTurnedOffStaysOff() {
    var rig = Rig(mode: .automaticPaused)
    rig.answersMonitors = false
    rig.state.suppressed = [dell]
    // Nothing is ever off that the record does not already name.
    rig.state.recordedSuppression = [dell]
    rig.state.guardian = .ready
    rig.send(answers(.otherMachine, at: 0), at: 0)
    // What the arrangement looks like afterwards: the monitor is gone, the laptop screen is on.
    var afterwards = withMonitor(suppressed: [dell], visible: 1)
    afterwards.externals = [.init(target: dell, suppressible: false, suppressed: true)]
    #expect(workers(rig.observe(afterwards, at: 100), .enable) == 0)
    #expect(workers(rig.send(.tick, at: 5000), .enable) == 0)

    // With nothing left to look at, it comes straight back.
    var blind = afterwards
    blind.visibleDisplays = 0
    #expect(workers(rig.observe(blind, at: 6000), .enable) == 1)
  }

  @Test func aMonitorComesBackWhenItHasSaidNothingForTooLong() {
    var rig = Rig(mode: .automaticPaused)
    rig.answersMonitors = false
    rig.state.suppressed = [dell]
    // Nothing is ever off that the record does not already name.
    rig.state.recordedSuppression = [dell]
    rig.state.guardian = .ready
    rig.observe(withMonitor(suppressed: [dell]), at: 0)
    rig.send(answers(.otherMachine, at: 100), at: 100)
    // A monitor usually answers again once it is switched back. This is the backstop for one
    // that never does, and it must not fire early.
    #expect(workers(rig.send(.tick, at: 200_000), .enable) == 0)
    #expect(workers(rig.send(.tick, at: 400_000), .enable) == 1)
  }

  @Test func aMonitorComesBackWhenTheMacIsNoLongerInFrontOfItsUser() {
    var rig = Rig(mode: .automaticPaused)
    rig.answersMonitors = false
    rig.state.suppressed = [dell]
    // Nothing is ever off that the record does not already name.
    rig.state.recordedSuppression = [dell]
    rig.state.guardian = .ready
    var asleep = withMonitor(suppressed: [dell])
    asleep.power = .sleeping
    #expect(workers(rig.observe(asleep, at: 0), .enable) == 1)
  }

  /// Seen on hardware on 2026-09-20: a monitor was unplugged while owed and every attempt to give
  /// it back failed because its ID named nothing. Seen on 2026-11-12: that same monitor comes
  /// back still off when it is plugged in again. So it stays owed, and the attempts wait longer
  /// each time instead of going out without pause or being given up.
  @Test func aMonitorThatCannotBeTurnedBackOnYetIsRetriedNotForgotten() {
    var rig = Rig(mode: .automaticPaused)
    rig.answersMonitors = false
    rig.state.suppressed = [dell]
    rig.state.recordedSuppression = [dell]
    rig.state.guardian = .ready
    rig.state.guardianTargets = [dell]
    var gone = withMonitor(suppressed: [dell], visible: 1)
    gone.visibleDisplays = 0
    #expect(workers(rig.observe(gone, at: 0), .enable) == 1)

    // A reading taken after the attempt is what judges it. The next one waits.
    rig.send(.workerFinished(.failed), at: 100)
    let missed = rig.observe(gone, at: 200)
    #expect(workers(missed, .enable) == 0)
    #expect(missed.contains(.wakeAt(700)))
    #expect(workers(rig.send(.tick, at: 699), .enable) == 0)
    #expect(workers(rig.send(.tick, at: 700), .enable) == 1)

    // Longer the second time, and still owed after more misses than it used to take to give up.
    rig.send(.workerFinished(.failed), at: 800)
    rig.observe(gone, at: 900)
    #expect(workers(rig.send(.tick, at: 1800), .enable) == 0)
    #expect(workers(rig.send(.tick, at: 1900), .enable) == 1)
    rig.send(.workerFinished(.failed), at: 2000)
    rig.observe(gone, at: 2100)
    #expect(rig.state.suppressed == [dell])
    #expect(!rig.send(.tick, at: 2200).contains(.recordSuppression([])))
    // The laptop screen's own backoff is untouched.
    #expect(rig.state.retryAt == nil)
  }

  /// Seen on hardware on 2026-11-11: the monitor was turned off for showing another machine, the
  /// screens went to sleep, and the restore that asked for was refused twice because every screen
  /// was asleep. The monitor was given up on, so switching it back to this Mac the next morning
  /// changed nothing. A refused restore keeps it owed, and switching back brings it back at once.
  @Test func aMonitorRefusedWhileTheScreensSleepComesBackWhenSwitchedToThisMac() {
    var rig = Rig(mode: .automaticPaused)
    rig.answersMonitors = false
    rig.state.suppressed = [dell]
    rig.state.recordedSuppression = [dell]
    rig.state.guardian = .ready
    rig.state.guardianTargets = [dell]
    rig.send(answers(.otherMachine, at: 0), at: 0)
    rig.send(answers(.otherMachine, at: 100), at: 100)
    let away = withMonitor(suppressed: [dell], visible: 1)
    #expect(workers(rig.observe(away, at: 200), .enable) == 0)

    // Every screen asleep: nothing is visible, so the monitor is asked back, and the worker
    // refuses because a screen that is asleep cannot be restored.
    let asleep = withMonitor(environment(panelState: .unknown), suppressed: [dell], visible: 0)
    #expect(workers(rig.observe(asleep, at: 1000), .enable) == 1)
    rig.send(.workerFinished(.refused), at: 1100)
    rig.observe(asleep, at: 1200)
    #expect(workers(rig.send(.tick, at: 1700), .enable) == 1)
    rig.send(.workerFinished(.refused), at: 1800)
    rig.observe(asleep, at: 1900)
    #expect(rig.state.suppressed == [dell])

    // The screens wake with the monitor still on the other machine: it stays off.
    let awake = withMonitor(suppressed: [dell], visible: 1)
    #expect(workers(rig.observe(awake, at: 2000), .enable) == 0)
    // Switched back to this Mac. One answer is enough, and the wait from the last miss is over.
    #expect(rig.send(answers(.thisMac, at: 2100), at: 2100).contains(.runWorker(.enable, dell)))
    rig.send(.workerFinished(.done), at: 2200)
    rig.observe(withMonitor(), at: 2300)
    #expect(rig.state.suppressed.isEmpty)
    #expect(rig.state.monitorRetryAt.isEmpty)
  }

  /// The laptop screen is never behind a monitor. There is one worker at a time, and the screen
  /// is the one a person cannot do without.
  @Test func monitorWorkNeverTakesTheSlotTheLaptopScreenNeeds() {
    var rig = Rig(mode: .automatic)
    rig.answersMonitors = false
    rig.state.suppressed = [dell]
    rig.state.recordedSuppression = [dell]
    rig.state.guardian = .ready
    // The screen is off and should come back, which outranks anything owed to a monitor.
    var wrong = withMonitor(environment(panelState: .disabled), suppressed: [dell], visible: 1)
    wrong.nativeExternalAvailable = .no
    let effects = rig.observe(wrong, at: 0)
    #expect(workers(effects, .enable) == 1)
    #expect(effects.contains(.runWorker(.enable, panel)))
  }

  /// Seen on hardware on 2026-11-12: a monitor this app turned off was unplugged and plugged in
  /// again, and it came back still off. So unplugging does not discharge it: nothing is tried
  /// while it is away, and it comes back once it is plugged in showing this Mac.
  @Test func anUnpluggedMonitorStaysOwedAndComesBackWhenPluggedInShowingThisMac() {
    var rig = Rig(mode: .automaticPaused)
    rig.answersMonitors = false
    rig.state.suppressed = [dell]
    rig.state.recordedSuppression = [dell]
    rig.observe(withMonitor(suppressed: [dell]), at: 0)
    // Its endpoint no longer answers at all, which is what unplugging looks like.
    let gone = rig.send(.inputSourcesRead(.unknown, monitors: [], sampledAt: 100), at: 100)
    #expect(rig.state.suppressed == [dell])
    #expect(workers(gone, .enable) == 0)
    #expect(!gone.contains(.recordSuppression([])))
    // Plugged in again, still off, and showing this Mac.
    #expect(rig.send(answers(.thisMac, at: 200), at: 200).contains(.runWorker(.enable, dell)))
  }

  /// A monitor that comes back on by itself while owed, such as one plugged in again on a Mac
  /// that does not keep it off, has said nothing since. It is not turned off on the answer it
  /// gave before it went away.
  @Test func aMonitorThatComesBackOnByItselfIsNotTurnedOffOnAnOldAnswer() {
    var rig = Rig(mode: .automaticPaused)
    rig.answersMonitors = false
    rig.state.suppressed = [dell]
    rig.state.recordedSuppression = [dell]
    rig.state.guardian = .ready
    rig.state.guardianTargets = [dell]
    rig.send(answers(.otherMachine, at: 0), at: 0)
    rig.send(answers(.otherMachine, at: 100), at: 100)
    rig.observe(withMonitor(suppressed: [dell], visible: 1), at: 200)
    rig.send(.inputSourcesRead(.unknown, monitors: [], sampledAt: 300), at: 300)
    // Back in the inventory and on, with nothing said yet.
    #expect(workers(rig.observe(withMonitor(), at: 400), .disable) == 0)
    #expect(workers(rig.send(.tick, at: 5000), .disable) == 0)
    // Its first answer settles it, and a monitor showing this Mac is simply discharged.
    #expect(rig.send(answers(.thisMac, at: 5100), at: 5100).contains(.runWorker(.enable, dell)))
    rig.send(.workerFinished(.done), at: 5200)
    rig.observe(withMonitor(), at: 5300)
    #expect(rig.state.suppressed.isEmpty)
  }
}

/// Seen on hardware on 2026-09-20: a guardian was running for a monitor, the laptop screen was
/// then turned off without telling it, and when the monitor was unplugged nothing brought the
/// screen back. A guardian that does not know about something cannot give it back.
struct GuardianKnowledgeTests {
  private let dell = PanelTarget(
    displayID: 4, displayUUID: "dell", bootID: "boot-1", loginID: 42,
    kind: .external, controller: "dispext0"
  )

  @Test func theLaptopScreenIsNeverTurnedOffWithoutTellingTheGuardian() {
    let other = PanelTarget(
      displayID: 7, displayUUID: "benq", bootID: "boot-1", loginID: 42,
      kind: .external, controller: "dispext1"
    )
    // One monitor is already off and held by a running guardian, another is showing this Mac,
    // and the laptop screen is about to go off because of it.
    var arrangement = environment()
    arrangement.externals = [
      .init(target: dell, suppressible: false, suppressed: true),
      .init(target: other, suppressible: true, suppressed: false)
    ]
    arrangement.visibleDisplays = 2

    var rig = Rig()
    rig.answersMonitors = false
    rig.state.suppressed = [dell]
    rig.state.recordedSuppression = [dell]
    rig.state.guardian = .ready
    rig.state.guardianTargets = [dell]

    rig.observe(arrangement, at: 0)
    rig.observe(arrangement, at: 2000)
    rig.send(.inputSourcesRead(.yes, sampledAt: 2100), at: 2100)
    let recorded = rig.send(.recordWritten(panel, succeeded: true), at: 2200)
    // Told about the panel before any worker runs, and told the whole set rather than a change.
    #expect(recorded.contains(.updateGuardian([panel, dell])))
    #expect(workers(recorded, .disable) == 0)
    #expect(rig.state.guardianTargets == [panel, dell])
    // Only then is the screen turned off.
    #expect(workers(rig.observe(arrangement, at: 2300), .disable) == 1)
  }

  @Test func aGuardianThatGoesAwayIsHoldingNothing() {
    var rig = Rig()
    rig.state.guardian = .ready
    rig.state.guardianTargets = [panel]
    rig.send(.guardianGone, at: 0)
    #expect(rig.state.guardianTargets.isEmpty)
  }
}

struct ExperimentalSuppressionRecoveryTests {
  @Test func disablingDetectionRestoresAnOwedMonitorBeforeTurningThePanelOff() {
    var rig = Rig()
    rig.answersMonitors = false
    rig.state.suppressed = [dell]
    rig.state.recordedSuppression = [dell]
    rig.state.guardian = .ready
    rig.observe(withMonitor(suppressed: [dell], visible: 1), at: 0)
    let effects = rig.send(.setInputDetection(false), at: 100)
    #expect(effects.contains(.runWorker(.enable, dell)))
    #expect(!effects.contains(.writeRecord(panel)))
    #expect(!effects.contains(.readInputSources))
    rig.send(.workerFinished(.done), at: 200)
    rig.observe(withMonitor(), at: 300)
    #expect(rig.state.suppressed.isEmpty)
    rig.send(.suppressionRecorded([], succeeded: true), at: 400)
    #expect(startsTurningOff(rig.observe(withMonitor(), at: 2400)))
  }

  @Test func defaultOffRestoresSuppressionInheritedFromAnEarlierRun() {
    var rig = Rig(inputDetectionEnabled: false)
    rig.answersMonitors = false
    rig.state.suppressed = [dell]
    let first = rig.observe(withMonitor(suppressed: [dell], visible: 1), at: 0)
    #expect(first.contains(.recordSuppression([dell])))
    let recorded = rig.send(.suppressionRecorded([dell], succeeded: true), at: 100)
    #expect(recorded.contains(.runWorker(.enable, dell)))
    #expect(!recorded.contains(.readInputSources))
  }

  @Test func disablingDuringAnExternalDisableRestoresItAfterTheWorkerFinishes() {
    var rig = Rig(mode: .automaticPaused)
    rig.answersMonitors = false
    rig.observe(withMonitor(), at: 0)
    rig.observe(withMonitor(), at: 2000)
    rig.send(answers(.otherMachine, at: 2100), at: 2100)
    rig.send(answers(.otherMachine, at: 3200), at: 3200)
    rig.send(.tick, at: 3300)
    rig.send(.suppressionRecorded([dell], succeeded: true), at: 3400)
    #expect(rig.send(.guardianReady, at: 3500).contains(.runWorker(.disable, dell)))
    let toggled = rig.send(.setInputDetection(false), at: 3600)
    #expect(workers(toggled, .enable) == 0)
    rig.send(.workerFinished(.done), at: 3700)
    #expect(rig.observe(withMonitor(suppressed: [dell], visible: 1), at: 3800)
      .contains(.runWorker(.enable, dell)))
  }

  @Test func unansweredPollsDoNotResetSilenceRecovery() {
    var rig = Rig(mode: .automaticPaused)
    rig.answersMonitors = false
    rig.state.suppressed = [dell]
    rig.state.recordedSuppression = [dell]
    rig.state.guardian = .ready
    rig.observe(withMonitor(suppressed: [dell], visible: 1), at: 0)
    rig.send(answers(.otherMachine, at: 0), at: 0)
    rig.send(answers(.otherMachine, at: 100), at: 100)
    for time in stride(from: Instant(10000), through: 300_000, by: 10000) {
      #expect(workers(rig.send(answers(.unknown, at: time), at: time), .enable) == 0)
    }
    #expect(rig.state.monitors["dispext0"]?.lastAnswered == 100)
    #expect(rig.send(.tick, at: 300_100).contains(.runWorker(.enable, dell)))
    rig.send(.workerFinished(.done), at: 300_200)
    rig.observe(withMonitor(), at: 300_300)
    rig.send(.suppressionRecorded([], succeeded: true), at: 300_400)
    rig.observe(withMonitor(), at: 332_000)
    #expect(rig.state.suppressed.isEmpty)
    #expect(rig.state.worker == nil)
  }
}
