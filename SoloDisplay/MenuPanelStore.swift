import Observation

/// Holds the panel for the hosting controller, which is built once and never rebuilt. Only this
/// value changes, so a refresh cannot churn the view tree underneath someone's pointer.
@Observable @MainActor
final class MenuPanelStore {
  private(set) var panel: MenuPanel = .placeholder
  var perform: (MenuAction) -> Void = { _ in }

  /// A second equality guard, independent of the controller's. The protection timer runs five
  /// times a second, and neither guard is expensive enough to be worth choosing between.
  func update(_ next: MenuPanel) {
    guard next != panel else { return }
    panel = next
  }
}
