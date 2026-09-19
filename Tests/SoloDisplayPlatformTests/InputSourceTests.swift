import SoloDisplayCore
import Testing
@testable import SoloDisplayPlatform

/// Fixtures captured from the tested Mac on 2026-09-19 with the Dell U3223QE on USB-C, by reading
/// VCP 0x60 while switching the monitor between its inputs. `0x1B` is its USB-C input, `0x0F`
/// DisplayPort 1 and `0x11` HDMI 1. Recorded evidence for this monitor, not a universal contract:
/// the high byte carrying the asking host's input is not in the standard.
private let showingTheMac: [UInt8] =
  [0x6E, 0x88, 0x02, 0x00, 0x60, 0x00, 0x1B, 0x1B, 0x1B, 0x1B, 0xD4, 0x6E]
private let showingDisplayPort: [UInt8] =
  [0x6E, 0x88, 0x02, 0x00, 0x60, 0x00, 0x1B, 0x1B, 0x1B, 0x0F, 0xC0, 0x00]
private let showingHDMI: [UInt8] =
  [0x6E, 0x88, 0x02, 0x00, 0x60, 0x00, 0x1B, 0x1B, 0x1B, 0x11, 0xDE, 0x00]

private func evidence(_ bytes: [UInt8]) -> InputSourceEvidence {
  .init(
    controller: "dispext0",
    reply: DDCPacket.parseReply(bytes, code: DDCPacket.inputSource)
  )
}

private func evidence(current: UInt16, maximum: UInt16 = 0x1B1B) -> InputSourceEvidence {
  .init(controller: "dispext0", reply: DDCValue(current: current, maximum: maximum))
}

struct InputSourceTests {
  @Test func capturedHardwareSaysWhichInputIsOnScreen() {
    #expect(
      DDCPacket.parseReply(showingTheMac, code: DDCPacket.inputSource)
        == DDCValue(current: 0x1B1B, maximum: 0x1B1B)
    )
    #expect(evidence(showingTheMac).shown == .thisMac)
    #expect(evidence(showingDisplayPort).shown == .otherMachine)
    #expect(evidence(showingHDMI).shown == .otherMachine)
  }

  @Test func aReservedHighByteIsNotEvidence() {
    // A monitor following the standard leaves the high byte empty. That says nothing about which
    // input is ours, so it can never mean the monitor is showing someone else.
    #expect(evidence(current: 0x001B).shown == .unknown)
    #expect(evidence(current: 0x1B00).shown == .unknown)
    #expect(evidence(current: 0x0000).shown == .unknown)
  }

  @Test func aMonitorThatDoesNotAnswerSaysNothing() {
    #expect(InputSourceEvidence(controller: "dispext0", reply: nil).shown == .unknown)
    // The second monitor tested on 2026-09-19 acknowledges the bus and returns a null message to
    // every request, whatever was asked. It never reaches a verdict.
    let nullMessage: [UInt8] = [0x6E, 0x80, 0xBE, 0x00, 0xE6, 0xD2, 0xD0, 0xA4, 0x0A, 0xF9,
                                0xAB, 0x2F]
    #expect(DDCPacket.parseReply(nullMessage, code: DDCPacket.inputSource) == nil)
    #expect(evidence(nullMessage).shown == .unknown)
  }

  @Test func theMaximumFieldIsNeverEvidence() {
    #expect(evidence(current: 0x1B1B, maximum: 0).shown == .thisMac)
    #expect(evidence(current: 0x1B0F, maximum: 0xFFFF).shown == .otherMachine)
  }

  @Test func oneMonitorShowingThisMacOutweighsOneShowingAnother() {
    let mac = evidence(showingTheMac)
    let other = evidence(showingDisplayPort)
    let silent = InputSourceEvidence(controller: "dispext1", reply: nil)
    #expect(InputSourceClassifier.showingThisMac([]) == .unknown)
    #expect(InputSourceClassifier.showingThisMac([silent]) == .unknown)
    #expect(InputSourceClassifier.showingThisMac([mac]) == .yes)
    #expect(InputSourceClassifier.showingThisMac([other]) == .no)
    // A monitor that cannot answer never lifts a refusal another monitor raised.
    #expect(InputSourceClassifier.showingThisMac([other, silent]) == .no)
    #expect(InputSourceClassifier.showingThisMac([other, mac]) == .yes)
    #expect(InputSourceClassifier.showingThisMac([mac, silent]) == .yes)
  }
}
