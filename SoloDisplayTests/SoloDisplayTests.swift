import Testing
@testable import SoloDisplay

@MainActor
struct SoloDisplayTests {
  @Test func historyIsBoundedAndIDsAreNotReused() {
    var history = DiagnosticHistory(capacity: 2)
    for value in 0 ..< 5 {
      history.append(milliseconds: Int64(value), reason: "fixture", detail: "synthetic")
    }
    #expect(history.entries.map(\.id) == [4, 5])
    #expect(history.discarded == 3)
  }

  @Test func historyHasAtLeastOneSlot() {
    var history = DiagnosticHistory(capacity: 0)
    history.append(milliseconds: 0, reason: "fixture", detail: "synthetic")
    #expect(history.entries.count == 1)
  }

  @Test func absentInventoryNeverClaimsThereAreNoDisplays() {
    #expect(
      DiagnosticPresentation.headline(inventoryAvailable: false, mirrored: false)
        == "Display inventory unavailable"
    )
  }

  @Test func mirroredTopologyIsExplicit() {
    #expect(
      DiagnosticPresentation.headline(inventoryAvailable: true, mirrored: true)
        == "Mirroring detected"
    )
  }

  @Test func inactivePanelIsNotPresentedAsVerifiedOff() {
    #expect(
      DiagnosticPresentation.activity(active: false, asleep: false)
        == "Not active (not proof of off)"
    )
  }
}
