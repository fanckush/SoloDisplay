import AppKit
import SwiftUI

/// The menu bar menu. A native menu, with the two arrangement cards as its only custom row.
///
/// A real menu is what keeps an auto-hidden menu bar down while it is open, and it starts fresh
/// every time it opens. A custom view inside a menu cannot become key, so anything that is a
/// control rather than a picture of the choice is a standard item: its checkmark, keyboard
/// navigation and highlighting are the system's.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
  let menu = NSMenu()
  private let store: MenuPanelStore
  private let perform: (MenuAction) -> Void
  private let alertItem = NSMenuItem()
  private let retryItem = NSMenuItem()
  private let alertSeparator = NSMenuItem.separator()
  private let arrangementItem = NSMenuItem()
  private let launchItem = NSMenuItem()
  private let brightnessItem = NSMenuItem()

  init(store: MenuPanelStore, perform: @escaping (MenuAction) -> Void) {
    self.store = store
    self.perform = perform
    super.init()
    menu.delegate = self
    menu.autoenablesItems = false

    alertItem.isEnabled = false
    alertItem.image = NSImage(
      systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil
    )
    configure(retryItem, title: "Try Again", action: .retryRecovery)
    configure(launchItem, title: store.panel.launchAtLogin.title, action: .toggleLaunchAtLogin)
    configure(
      brightnessItem, title: store.panel.brightnessKeys.title, action: .toggleBrightnessKeys
    )
    for item in [
      alertItem, retryItem, alertSeparator, arrangementItem, .separator(), launchItem,
      brightnessItem
    ] {
      menu.addItem(item)
    }
    menu.addItem(.separator())
    for command in store.panel.commands {
      let item = NSMenuItem()
      configure(item, title: command.title, action: command.action)
      if command.action == .quit {
        item.keyEquivalent = "q"
      }
      menu.addItem(item)
    }
    update(store.panel)
  }

  /// Standard items follow the panel while the menu is open. The cards follow it on their own,
  /// through the store.
  func update(_ panel: MenuPanel) {
    alertItem.title = panel.alert?.title ?? ""
    alertItem.subtitle = panel.alert?.detail
    alertItem.isHidden = panel.alert == nil
    retryItem.isHidden = panel.alert?.retry == nil
    alertSeparator.isHidden = panel.alert == nil
    launchItem.title = panel.launchAtLogin.title
    launchItem.state = panel.launchAtLogin.isOn ? .on : .off
    brightnessItem.title = panel.brightnessKeys.title
    // A dash rather than a subtitle, so the menu keeps its size while permission is missing.
    brightnessItem.state = panel.brightnessKeys.isBlocked
      ? .mixed : panel.brightnessKeys.isOn ? .on : .off
  }

  func menuNeedsUpdate(_: NSMenu) {
    update(store.panel)
    // A new view on every open, so nothing is carried over from the last time the menu was open.
    let hosting = NSHostingView(rootView: ArrangementView(store: store))
    // Measured and sized here, before the menu asks. A menu asks an item's view for its size as
    // it opens and does not ask again, so a view that only reaches its size at the next layout
    // opens the menu at the wrong width until something else makes it lay out.
    hosting.frame = .init(origin: .zero, size: hosting.fittingSize)
    // The menu is as wide as its widest item, which is usually one of the standard ones. The row
    // follows that width rather than sitting at its own, so the cards line up with everything
    // below them instead of leaving a gap down one side.
    hosting.autoresizingMask = [.width]
    arrangementItem.view = hosting
  }

  private func configure(_ item: NSMenuItem, title: String, action: MenuAction) {
    item.title = title
    item.target = self
    item.action = #selector(choose(_:))
    item.representedObject = action.rawValue
  }

  @objc private func choose(_ item: NSMenuItem) {
    guard let raw = item.representedObject as? String, let action = MenuAction(rawValue: raw)
    else { return }
    perform(action)
  }
}
