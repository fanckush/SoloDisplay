import Testing
@testable import SoloDisplayCore

struct InputDetectionSettingsTests {
  @Test func detectionDefaultsOffAndNormalAutomationNeedsNoDDC() {
    #expect(!ControllerState().inputDetectionEnabled)
    var rig = Rig(inputDetectionEnabled: false)
    rig.answersMonitors = false
    #expect(!rig.observe(at: 0).contains(.readInputSources))
    #expect(startsTurningOff(rig.observe(at: 2000)))
    rig.send(.recordWritten(panel, succeeded: true), at: 2001)
    #expect(rig.send(.guardianReady, at: 2002).contains(.runWorker(.disable, panel)))
    rig.send(.workerFinished(.done), at: 2010)
    rig.observe(environment(panelState: .disabled), at: 2020)
    #expect(!rig.send(.tick, at: 20000).contains(.readInputSources))
    #expect(rig.observe(environment(panelState: .disabled, external: .no), at: 21000)
      .contains(.runWorker(.enable, panel)))
  }

  @Test func disablingDetectionClearsItsRefusalAndIgnoresLateReplies() {
    var rig = Rig()
    rig.monitorAnswer = .no
    rig.observe(at: 0)
    rig.observe(at: 2000)
    #expect(rig.state.inputRefusal)
    #expect(startsTurningOff(rig.send(.setInputDetection(false), at: 2100)))
    #expect(!rig.state.inputRefusal)
    #expect(rig.state.inputSources == .unknown)
    rig.send(.inputSourcesRead(.no, monitors: [], sampledAt: 2200), at: 2200)
    #expect(!rig.state.inputRefusal)
    #expect(rig.state.inputSources == .unknown)
    #expect(!rig.state.inputSourcesBusy)
  }

  @Test func enablingDetectionStartsAFreshSweep() {
    var rig = Rig(mode: .automaticPaused, inputDetectionEnabled: false)
    rig.answersMonitors = false
    rig.observe(at: 0)
    #expect(rig.send(.setInputDetection(true), at: 100).contains(.readInputSources))
    #expect(rig.state.inputSourcesBusy)
  }
}
