import SwiftUI

/// The menu bar panel. Two arrangements, one line saying what is actually true, and the few
/// commands that are not a choice about displays.
struct MenuPanelView: View {
  let store: MenuPanelStore

  private var panel: MenuPanel {
    store.panel
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let alert = panel.alert {
        alertRow(alert)
        Divider()
      }
      choices
      Divider()
      commands
    }
    .frame(width: 300)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var choices: some View {
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
    .padding(14)
  }

  private func alertRow(_ alert: MenuPanel.Alert) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Group {
        if alert.severity == .working {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      }
      .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(alert.title).font(.system(size: 12, weight: .semibold))
        Text(alert.detail)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let retry = alert.retry {
          Button("Try Again") { store.perform(retry) }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .padding(.top, 1)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(14)
  }

  private var commands: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Text(panel.launchAtLogin.title).font(.system(size: 12))
        Spacer(minLength: 8)
        Toggle("", isOn: Binding(
          get: { panel.launchAtLogin.isOn },
          set: { _ in store.perform(panel.launchAtLogin.action) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 7)

      Divider().padding(.vertical, 4)

      ForEach(panel.commands, id: \.action) { command in
        CommandRow(title: command.title) { store.perform(command.action) }
      }
    }
    .padding(.bottom, 6)
  }
}

/// A menu-like row. Plain buttons rather than a List, so the panel keeps menu proportions
/// instead of inheriting a table's.
private struct CommandRow: View {
  let title: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: 5)
        .fill(hovering ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
    )
    .onHover { hovering = $0 }
    .padding(.horizontal, 6)
  }
}
