import Testing
@testable import SoloDisplayPlatform

struct PrivateDisplayModeTests {
  private func record(width: UInt32, height: UInt32, density: Float, length: Int = 212) -> [UInt8] {
    var bytes = [UInt8](repeating: 0xAB, count: length)
    bytes.withUnsafeMutableBytes { raw in
      raw.storeBytes(of: Int32(42), toByteOffset: 0, as: Int32.self)
      raw.storeBytes(of: UInt32(0x3), toByteOffset: 4, as: UInt32.self)
      raw.storeBytes(of: width, toByteOffset: 8, as: UInt32.self)
      raw.storeBytes(of: height, toByteOffset: 12, as: UInt32.self)
      raw.storeBytes(of: UInt32(32), toByteOffset: 16, as: UInt32.self)
      if length == 212 {
        raw.storeBytes(of: UInt16(165), toByteOffset: 190, as: UInt16.self)
        raw.storeBytes(of: density, toByteOffset: 208, as: Float.self)
      }
    }
    return bytes
  }

  @Test func readsTheKnownFields() {
    let mode = record(width: 1920, height: 1080, density: 2).withUnsafeBytes {
      PrivateDisplayMode.decode($0)
    }
    #expect(mode == .init(
      number: 42, flags: 3, width: 1920, height: 1080, depth: 32, frequency: 165, density: 2
    ))
    #expect(mode.map(DisplayModeCatalog.summary)?.scale == 2)
    #expect(mode.map(DisplayModeCatalog.summary)?.usable == true)
  }

  @Test func rejectsARecordThatCannotBeAMode() {
    for bytes in [
      record(width: 1920, height: 1080, density: 2, length: 200),
      record(width: 0, height: 1080, density: 2),
      record(width: 1920, height: 1080, density: .nan),
      record(width: 1920, height: 1080, density: 0)
    ] {
      #expect(bytes.withUnsafeBytes { PrivateDisplayMode.decode($0) } == nil)
    }
  }

  @Test func scaleIsOnlyOneOrTwo() {
    #expect(DisplayModeCatalog.scale(
      width: 1920,
      height: 1080,
      pixelWidth: 1920,
      pixelHeight: 1080
    ) == 1)
    #expect(DisplayModeCatalog.scale(
      width: 1920,
      height: 1080,
      pixelWidth: 3840,
      pixelHeight: 2160
    ) == 2)
    #expect(DisplayModeCatalog.scale(
      width: 1920,
      height: 1080,
      pixelWidth: 2560,
      pixelHeight: 1440
    ) == 0)
    #expect(DisplayModeCatalog.scale(width: 0, height: 0, pixelWidth: 0, pixelHeight: 0) == 0)
  }

  /// Flags read off the Y27h-30 with 1080p at 2x active, 2026-10-08.
  @Test func onlyAHiddenTwoXModeIsSharpTextsKind() {
    // 1920x1080 at 2x, never listed by System Settings.
    #expect(DisplayModeCatalog.isHiddenSharp(scale: 2, flags: 0x0020_0003))
    // 1280x720 at 2x, which macOS offers itself, is left alone.
    #expect(!DisplayModeCatalog.isHiddenSharp(scale: 2, flags: 0x0200_0003))
    // Native at 1x.
    #expect(!DisplayModeCatalog.isHiddenSharp(scale: 1, flags: 0x0200_0007))
    #expect(!DisplayModeCatalog.isHiddenSharp(scale: 1, flags: 0x0020_0003))
  }
}
