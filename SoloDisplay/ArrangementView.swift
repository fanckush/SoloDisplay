import SwiftUI

/// The two arrangements, and one line saying what is actually true. This is the only custom row
/// in the menu bar menu; everything else there is a standard menu item.
struct ArrangementView: View {
  static let width: CGFloat = 300

  let store: MenuPanelStore

  var body: some View {
    let panel = store.panel
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 10) {
        DisplayTile(choice: panel.allMonitors, action: store.perform)
        DisplayTile(choice: panel.externalOnly, action: store.perform)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Display arrangement")
      // Reality, as opposed to the choice above it. Also where a blocked choice says why.
      Text(panel.reality)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.top, 8)
    .padding(.bottom, 6)
    .frame(width: Self.width)
    .fixedSize(horizontal: false, vertical: true)
  }
}
