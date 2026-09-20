import AppKit
import SoloDisplayCore
import SwiftUI
import Testing
@testable import SoloDisplay

/// The arrangement row is the one custom view in the menu. A menu asks an item's view for its
/// size once, as it opens, so a size that is only right after some later event is a menu that
/// opens at the wrong width and corrects itself when something happens to make it lay out again.
@MainActor
struct ArrangementViewTests {
  private func hosted(_ reality: String) -> NSHostingView<ArrangementView> {
    let store = MenuPanelStore()
    var panel = MenuPanel.placeholder
    panel.reality = reality
    store.update(panel)
    return NSHostingView(rootView: ArrangementView(store: store))
  }

  @Test func theRowIsTheSameWidthWhateverItSays() {
    let shortest = hosted("Just a moment.")
    let longest = hosted("2 monitors showing another computer are turned off.")
    #expect(shortest.fittingSize.width == ArrangementView.width)
    #expect(longest.fittingSize.width == ArrangementView.width)
  }

  /// The cards fill the row, so a row that follows a wider menu keeps them lined up with the
  /// items below rather than leaving a gap down one side.
  @Test func theCardsFillWhateverWidthTheRowIsGiven() {
    let row = hosted("Your laptop screen is off.")
    row.frame = .init(x: 0, y: 0, width: 360, height: row.fittingSize.height)
    row.layoutSubtreeIfNeeded()
    #expect(row.frame.width == 360)
    #expect(row.fittingSize.width == ArrangementView.width)
  }

  @Test func aLongerLineMakesTheRowTallerRatherThanWider() {
    let one = hosted("Just a moment.")
    let many = hosted("2 monitors showing another computer are turned off.")
    #expect(many.fittingSize.height >= one.fittingSize.height)
  }
}

/// The menu asks an item's view for its size as it opens, and does not ask again. A view that
/// arrives without one opens the menu at the wrong width, and only corrects when some later
/// event makes it lay out, which is what a keypress does.
@MainActor
struct StatusMenuSizingTests {
  @Test func theArrangementRowArrivesAtItsFullSize() {
    let store = MenuPanelStore()
    var panel = MenuPanel.placeholder
    panel.reality = "2 monitors showing another computer are turned off."
    store.update(panel)
    let menu = StatusMenu(store: store, perform: { _ in })

    menu.menuNeedsUpdate(menu.menu)
    let row = menu.menu.items.compactMap(\.view).first
    #expect(row != nil)
    #expect(row?.frame.width == ArrangementView.width)
    #expect((row?.frame.height ?? 0) > 0)
    // And follows the menu when something else in it is wider.
    #expect(row?.autoresizingMask.contains(.width) == true)
  }

  @Test func theRowIsSizedFreshEveryTimeTheMenuOpens() {
    let store = MenuPanelStore()
    let menu = StatusMenu(store: store, perform: { _ in })
    menu.menuNeedsUpdate(menu.menu)
    let first = menu.menu.items.compactMap(\.view).first?.frame.height ?? 0

    var taller = MenuPanel.placeholder
    taller.reality = "2 monitors showing another computer are turned off."
    store.update(taller)
    menu.menuNeedsUpdate(menu.menu)
    let second = menu.menu.items.compactMap(\.view).first?.frame.height ?? 0
    #expect(second >= first)
  }
}
