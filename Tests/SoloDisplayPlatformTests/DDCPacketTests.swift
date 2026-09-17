import Testing
@testable import SoloDisplayPlatform

/// A brightness reply of 68 out of 100, shaped like the Dell U3223QE's reply over USB-C.
private let brightnessReply: [UInt8] = [
  0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x44, 0x84, 0x00
]

struct DDCPacketTests {
  @Test func requestsCarryTheStandardChecksum() {
    // 0xAC is the widely published checksum for reading brightness.
    #expect(DDCPacket.getRequest(code: DDCPacket.brightness) == [0x82, 0x01, 0x10, 0xAC])
    #expect(
      DDCPacket.setRequest(code: DDCPacket.brightness, value: 60)
        == [0x84, 0x03, 0x10, 0x00, 0x3C, 0x94]
    )
  }

  @Test func setRequestsSplitWideValues() {
    let request = DDCPacket.setRequest(code: 0x10, value: 0x0123)
    #expect(request[3] == 0x01)
    #expect(request[4] == 0x23)
  }

  @Test func aValidReplyDecodes() {
    #expect(
      DDCPacket.parseReply(brightnessReply, code: DDCPacket.brightness)
        == DDCValue(current: 68, maximum: 100)
    )
  }

  @Test func aDamagedOrForeignReplyIsRejected() {
    var corrupted = brightnessReply
    corrupted[9] = 0x45
    #expect(DDCPacket.parseReply(corrupted, code: 0x10) == nil)

    var unsupported = brightnessReply
    unsupported[3] = 0x01
    #expect(DDCPacket.parseReply(unsupported, code: 0x10) == nil)

    // A reply for another feature must not be read as brightness.
    #expect(DDCPacket.parseReply(brightnessReply, code: 0x12) == nil)
    #expect(DDCPacket.parseReply(Array(brightnessReply.prefix(10)), code: 0x10) == nil)
  }
}
