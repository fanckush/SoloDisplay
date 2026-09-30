import SoloDisplayCore
import Testing
@testable import SoloDisplay

private func menuPanel(_ value: Presentation) -> MenuPanel {
  MenuModel.panel(value, launchAtLogin: false)
}

struct ShortcutModelTests {
  @Test func toggleMovesAwayFromTheChosenArrangement() {
    #expect(ShortcutModel.toggled(from: menuPanel(.init(wantsInternalOff: false))) == .externalOnly)
    #expect(
      ShortcutModel.toggled(from: menuPanel(.init(wantsInternalOff: true, panelOff: true)))
        == .allMonitors
    )
  }

  @Test func toggleFollowsTheChoiceEvenWhileNoMonitorIsThere() {
    let waiting = menuPanel(.init(wantsInternalOff: true, unavailability: .noNativeExternal))
    #expect(ShortcutModel.toggled(from: waiting) == .allMonitors)
  }

  @Test func eachArrangementSendsTheSameActionAsItsTile() throws {
    let shown = menuPanel(.init(wantsInternalOff: false))
    #expect(try ShortcutModel.action(for: .allMonitors, in: shown) == shown.allMonitors.action)
    #expect(try ShortcutModel.action(for: .externalOnly, in: shown) == shown.externalOnly.action)
  }

  @Test func anUnavailableTileRefusesWithTheReasonTheMenuShows() throws {
    let noPanel = menuPanel(.init(unavailability: .noConfirmedPanel))
    #expect(throws: ShortcutRefusal.self) {
      try ShortcutModel.action(for: .externalOnly, in: noPanel)
    }
    do {
      _ = try ShortcutModel.action(for: .externalOnly, in: noPanel)
    } catch let refusal as ShortcutRefusal {
      #expect(refusal.reason == noPanel.reality)
    } catch {
      Issue.record("unexpected error \(error)")
    }
    // The laptop screen can always be asked to stay on.
    #expect(try ShortcutModel.action(for: .allMonitors, in: noPanel) == .selectAllMonitors)
  }

  @Test func nothingCanBeChosenWhenTheControllerIsNotRunning() {
    let stopped = menuPanel(.init(unavailability: .notRunning))
    for arrangement in [Arrangement.allMonitors, .externalOnly] {
      #expect(throws: ShortcutRefusal.self) {
        try ShortcutModel.action(for: arrangement, in: stopped)
      }
    }
  }
}
