import SoloDisplayCore
import Testing
@testable import SoloDisplayPlatform

private func display(id: UInt32, uuid: String, builtIn: Bool = false) -> DisplayReading {
  .init(
    id: id, uuid: uuid, uuidResolvedID: id, builtIn: builtIn, active: true, online: true,
    asleep: false, mirrored: false, mirrorSourceID: nil, width: 1920, height: 1080,
    originX: 0, originY: 0, modeAvailable: true, transport: DisplayTransport.native.rawValue
  )
}

private func reading(
  _ displays: [DisplayReading], controllers: [UInt32: String]
) -> PlatformReading {
  .init(
    osVersion: "27.0", monotonicMilliseconds: 0, enumerationError: nil, displays: displays,
    lid: .open, bootID: "boot-a", loginID: 501, foregroundSession: .yes, privateSymbol: nil,
    controllers: controllers, limitations: []
  )
}

/// A monitor that is switched away, or one SoloDisplay has turned off, keeps its DDC endpoint but
/// leaves CoreGraphics. What that endpoint carries can only be learned while it is still there.
struct ControllerCorrelationTests {
  @Test func anEndpointRemembersItsMonitorAfterTheDisplayIsGone() {
    let correlation = ControllerCorrelation()
    correlation.learn(reading([display(id: 4, uuid: "dell")], controllers: [4: "dispext0"]))
    #expect(correlation.target(for: "dispext0")?.displayUUID == "dell")

    // The display vanishes, as it does when it is turned off. The endpoint is still there.
    correlation.learn(reading([], controllers: [:]))
    #expect(correlation.target(for: "dispext0")?.displayUUID == "dell")
    #expect(correlation.target(for: "dispext0")?.displayID == 4)
  }

  /// An endpoint is a port, not a monitor. Unplug one monitor and plug in another and the same
  /// name carries something else, which must never be addressed as the first one.
  @Test func anEndpointCarryingANewMonitorForgetsTheOldOne() {
    let correlation = ControllerCorrelation()
    correlation.learn(reading([display(id: 4, uuid: "dell")], controllers: [4: "dispext0"]))
    correlation.learn(reading([display(id: 7, uuid: "benq")], controllers: [7: "dispext0"]))
    #expect(correlation.target(for: "dispext0")?.displayUUID == "benq")
    #expect(correlation.target(for: "dispext0")?.displayID == 7)
  }

  @Test func anEndpointThatIsGoneIsForgotten() {
    let correlation = ControllerCorrelation()
    correlation.learn(reading([display(id: 4, uuid: "dell")], controllers: [4: "dispext0"]))
    correlation.forget(keeping: ["dispext0"])
    #expect(correlation.target(for: "dispext0") != nil)
    // The monitor was unplugged, so its endpoint no longer enumerates at all.
    correlation.forget(keeping: [])
    #expect(correlation.target(for: "dispext0") == nil)
  }

  @Test func theBuiltInPanelIsNeverCorrelatedToAnEndpoint() {
    let correlation = ControllerCorrelation()
    correlation.learn(reading(
      [display(id: 1, uuid: "panel", builtIn: true)], controllers: [1: "disp0"]
    ))
    #expect(correlation.target(for: "disp0") == nil)
  }

  /// Identity is only valid inside the boot and login it was read in, so a reading that cannot
  /// say which those are teaches nothing.
  @Test func aReadingWithNoSessionIdentityTeachesNothing() {
    let correlation = ControllerCorrelation()
    var anonymous = reading([display(id: 4, uuid: "dell")], controllers: [4: "dispext0"])
    anonymous.bootID = nil
    correlation.learn(anonymous)
    #expect(correlation.target(for: "dispext0") == nil)
  }
}

/// What is owed and what the hardware is doing are two different things. A record says the first
/// and never the second: reading it as the second leaves a monitor on for ever, because nothing
/// would ever ask for it to be turned off.
struct ExternalCandidateTests {
  private let dell = PanelTarget(
    displayID: 4, displayUUID: "dell", bootID: "boot-a", loginID: 501,
    kind: .external, controller: "dispext0"
  )

  @Test func aMonitorThatIsOwedButStillThereIsNotOffYet() {
    let live = reading([display(id: 4, uuid: "dell")], controllers: [4: "dispext0"])
    let candidates = ControllerObservation.externals(live, reliable: true, suppressed: [dell])
    #expect(candidates.count == 1)
    #expect(candidates.first?.suppressed == false)
    #expect(candidates.first?.suppressible == true)
  }

  @Test func aMonitorThatIsOwedAndGoneIsOff() {
    let empty = reading([], controllers: [:])
    let candidates = ControllerObservation.externals(empty, reliable: true, suppressed: [dell])
    #expect(candidates.map(\.suppressed) == [true])
    // Nothing can be done to a display that is not there, so it is never a candidate.
    #expect(candidates.first?.suppressible == false)
  }

  /// A monitor other screens mirror can be turned off, measured on 2026-09-20. One that is
  /// itself following another screen is left alone: the same picture is already elsewhere.
  @Test func aMonitorFollowingAnotherScreenIsNotACandidate() {
    var follower = display(id: 4, uuid: "dell")
    follower.mirrorSourceID = 7
    let live = reading([follower], controllers: [4: "dispext0"])
    let candidates = ControllerObservation.externals(live, reliable: true, suppressed: [])
    #expect(candidates.first?.suppressible == false)
  }
}
