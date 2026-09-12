import AppKit
import SwiftUI

/// The menu bar panel. Two arrangements, one line saying what is actually true, and the few
/// commands that are not a choice about displays.
struct MenuPanelView: View {
  /// The two arrangements are the reason the panel exists, so opening it puts the keyboard on
  /// them. Without this the first focusable control took it, which was Launch at Login.
  private enum Tile: Hashable { case allMonitors, externalOnly }

  let store: MenuPanelStore
  @FocusState private var focus: Tile?
  @State private var keyboard = KeyboardNavigation()

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
    .onAppear {
      focus = panel.externalOnly.isSelected ? .externalOnly : .allMonitors
      keyboard.start()
    }
    .onDisappear { keyboard.stop() }
  }

  private var choices: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 10) {
        DisplayTile(choice: panel.allMonitors, action: store.perform)
          .focusable(panel.allMonitors.isEnabled)
          .focused($focus, equals: .allMonitors)
        DisplayTile(choice: panel.externalOnly, action: store.perform)
          .focusable(panel.externalOnly.isEnabled)
          .focused($focus, equals: .externalOnly)
      }
      // The ring is the system's, and it follows focus. Focus is placed as soon as the panel opens
      // so the first Tab lands on a tile, which would otherwise light a ring at every mouse click.
      .focusEffectDisabled(!keyboard.isActive)
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
        if !alert.detail.isEmpty {
          Text(alert.detail)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
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

/// Whether the person is navigating by keyboard, which is what a focus ring is meant to answer.
///
/// The panel puts focus on an arrangement as soon as it opens, so that the first Tab or arrow
/// lands there rather than on Launch at Login. That is logical focus only. Drawing a ring for it
/// would greet every mouse click with what looks like a stuck highlight, and the ring would then
/// sit there for the life of the panel because clicking elsewhere does not move a SwiftUI
/// `@FocusState`. AppKit draws its own rings on this distinction; SwiftUI does not expose it, so
/// the panel tracks it here. The keyboard raises the flag and the next click lowers it.
@Observable @MainActor
private final class KeyboardNavigation {
  private(set) var isActive = false
  @ObservationIgnored private var monitor: Any?

  /// Tab, Shift-Tab and the arrows are what move focus between the tiles. Any other key is
  /// someone typing rather than navigating and leaves the ring where it is.
  private static let navigationKeys: Set<UInt16> = [48, 123, 124, 125, 126]

  /// Local, so this sees only events already bound for this app, and only while the panel is up.
  func start() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
      guard let self else { return event }
      if event.type == .keyDown {
        if Self.navigationKeys.contains(event.keyCode) {
          isActive = true
        }
      } else {
        isActive = false
      }
      return event
    }
  }

  /// The hosting controller outlives any one showing, so the monitor has to come down with the
  /// panel rather than with the view. Left running it would watch every keystroke in the app while
  /// the panel is closed, and the ring would come back up already lit on the next open.
  func stop() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
    monitor = nil
    isActive = false
  }
}
