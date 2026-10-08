import Testing
@testable import SoloDisplayCore

/// A 1440p monitor like the Y27h-30: native 2560x1440, and 2x modes at 1080p and 1152p that only
/// the private list carries, at 165 Hz. 1080p 2x also exists at 60 Hz.
private func mode(_ width: Int, _ height: Int, _ scale: Int,
                  _ rate: Int = 165) -> DisplayModeSummary {
  .init(width: width, height: height, scale: scale, refreshRate: rate, number: Int32(width + scale))
}

private let qhd = [
  mode(2560, 1440, 1), mode(2560, 1440, 1, 60), mode(2048, 1152, 1), mode(2048, 1152, 2),
  mode(1920, 1080, 1), mode(1920, 1080, 1, 60), mode(1920, 1080, 2), mode(1920, 1080, 2, 60),
  mode(1600, 900, 1), mode(1280, 720, 1), mode(1280, 720, 2)
]
private let qhdNative = ModeSize(width: 2560, height: 1440)

@Test func belowNativeSwitchesToTheTwinAtTheSameSpeed() {
  let verdict = SharpText.verdict(current: mode(1920, 1080, 1), native: qhdNative, catalog: qhd)
  #expect(verdict == .wouldSwitch(to: mode(1920, 1080, 2)))
  let slow = SharpText.verdict(current: mode(1920, 1080, 1, 60), native: qhdNative, catalog: qhd)
  #expect(slow == .wouldSwitch(to: mode(1920, 1080, 2, 60)))
}

@Test func nativeIsLeftAlone() {
  #expect(SharpText.verdict(current: mode(2560, 1440, 1), native: qhdNative, catalog: qhd)
    == .atNative)
}

@Test func aSharpModeIsLeftAlone() {
  #expect(SharpText.verdict(current: mode(1920, 1080, 2), native: qhdNative, catalog: qhd)
    == .alreadySharp)
}

@Test func aSlowerTwinIsNotOffered() {
  let catalog = [mode(2560, 1440, 1), mode(1920, 1080, 1), mode(1920, 1080, 2, 60)]
  #expect(SharpText.verdict(current: mode(1920, 1080, 1), native: qhdNative, catalog: catalog)
    == .noTwin)
}

@Test func anUnusableTwinIsNotOffered() {
  var twin = mode(1920, 1080, 2)
  twin.usable = false
  let catalog = [mode(2560, 1440, 1), mode(1920, 1080, 1), twin]
  #expect(SharpText.verdict(current: mode(1920, 1080, 1), native: qhdNative, catalog: catalog)
    == .noTwin)
}

@Test func withoutANativeSizeNothingIsDecided() {
  #expect(SharpText.verdict(current: mode(1920, 1080, 1), native: nil, catalog: qhd)
    == .unknownNative)
}

@Test func theFlaggedNativeSizeWins() {
  let flagged = [qhdNative, qhdNative]
  #expect(SharpText.native(flagged: flagged, catalog: qhd) == qhdNative)
  // Two different flagged sizes is a contradiction, not a choice.
  let both = [qhdNative, ModeSize(width: 1920, height: 1080)]
  #expect(SharpText.native(flagged: both, catalog: qhd) == nil)
}

@Test func withNothingFlaggedTheLargestPlainModeStandsIn() {
  #expect(SharpText.native(flagged: [], catalog: qhd) == qhdNative)
  // Two sizes with the same area cannot be told apart.
  let tied = [mode(1920, 1200, 1), mode(1200, 1920, 1)]
  #expect(SharpText.native(flagged: [], catalog: tied) == nil)
}

@Test func a4KMonitorIsAlreadyHandledByMacOS() {
  let uhd = [mode(3840, 2160, 1, 60), mode(1920, 1080, 2, 60), mode(2560, 1440, 2, 60)]
  let native = ModeSize(width: 3840, height: 2160)
  #expect(SharpText.verdict(current: mode(2560, 1440, 2, 60), native: native, catalog: uhd)
    == .alreadySharp)
  #expect(SharpText.verdict(current: mode(3840, 2160, 1, 60), native: native, catalog: uhd)
    == .atNative)
}

@Test func theReportListsEverySizeThatCanBeSharp() {
  #expect(SharpText.sizes(catalog: qhd, native: qhdNative, refreshRate: 165) == [
    .init(width: 2048, height: 1152), .init(width: 1920, height: 1080),
    .init(width: 1280, height: 720)
  ])
  #expect(SharpText.sizes(catalog: qhd, native: qhdNative, refreshRate: 60) == [
    .init(width: 1920, height: 1080)
  ])
}

@Test func onlyAPlainModeBelowNativeIsACandidate() {
  #expect(SharpText.candidate(mode(1920, 1080, 1), native: qhdNative))
  #expect(!SharpText.candidate(mode(2560, 1440, 1), native: qhdNative))
  #expect(!SharpText.candidate(mode(1920, 1080, 2), native: qhdNative))
  #expect(!SharpText.candidate(mode(1920, 1080, 1), native: nil))
  // Wider than the panel in one direction is not below it.
  #expect(!SharpText.candidate(mode(3440, 1080, 1), native: qhdNative))
}
