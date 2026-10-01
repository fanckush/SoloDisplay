import Testing
@testable import SoloDisplayPlatform

struct ChipTests {
  @Test func onlyTheBaseM3IsWarnedAbout() {
    #expect(Chip.turningOnCanFreeze(brand: "Apple M3"))
    for other in ["Apple M3 Pro", "Apple M3 Max", "Apple M2", "Apple M4", "Apple M5 Pro", ""] {
      #expect(!Chip.turningOnCanFreeze(brand: other), "\(other) was warned about")
    }
  }

  @Test func thisMacReportsItsChip() {
    #expect(Chip.brand?.hasPrefix("Apple") == true)
  }
}
