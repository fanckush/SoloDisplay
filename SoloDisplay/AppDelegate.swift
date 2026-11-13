import AppKit
import CoreGraphics
import Darwin
import Foundation
import SoloDisplayPlatform
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let diagnostics = DiagnosticsModel()
  private var statusItem: NSStatusItem?
  private var diagnosticsWindow: NSWindow?
  private var controller: ControllerRuntime?
  private var guardian: GuardianRuntime?
  private var lastGlyph: MenuGlyph?
  private var statusMenu: StatusMenu?
  private let panelStore = MenuPanelStore()
  private var updater: Updater?
  private var knownScreens: Set<CGDirectDisplayID> = []
  private let operationalDiagnostics = OperationalLogger(role: .bootstrap)
  /// The icon is hidden by choice but shown for now, because the app was opened again.
  private var iconRevealed = false
  /// A revealed icon stays at least this long, so a menu that closes at once, as it does when
  /// switching desktops, does not take the icon with it before it can be seen.
  private static let revealGrace: TimeInterval = 2
  private var revealedUntil = Date.distantPast
  private var hideTimer: Timer?
  /// Waits for a revealed icon to be in place before clicking it.
  private var clickTimer: Timer?
  private var menuOpen = false
  /// Posted by a second copy on its way out, so the copy that is running shows its menu.
  private static let revealNotification = Notification.Name(
    "\(Bundle.main.bundleIdentifier ?? "SoloDisplay").revealMenu"
  )

  func applicationDidFinishLaunching(_: Notification) {
    // Unit tests exercise the model without starting the platform observer.
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    // A write to a child that has gone away must surface as an error, not kill this process.
    signal(SIGPIPE, SIG_IGN)
    let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
    do {
      let role = try ProductionLaunch.role(
        arguments: arguments, pipedStandardStreams: ProductionLaunch.standardStreamsArePipes()
      )
      switch role {
      case .app: startApp()
      case .guardian: startGuardian()
      case .worker: startWorker()
      case .unprotected: startUnprotectedInterface()
      }
    } catch {
      operationalDiagnostics.emit(
        .startupFailed, reason: .invalidLaunch, errorCode: (error as NSError).code
      )
      FileHandle.standardError.write(Data("SoloDisplay: \(error)\n".utf8))
      exit(64)
    }
  }

  private func startApp() {
    operationalDiagnostics.started()
    NSApp.setActivationPolicy(.accessory)
    let runtime = ControllerRuntime(
      diagnostics: .init(role: .app, run: operationalDiagnostics.run)
    )
    guard runtime.start() else {
      FileHandle.standardError.write(
        Data("SoloDisplay is already running in this login session.\n".utf8)
      )
      // Launched from the Finder this is otherwise an app that opens and vanishes, with the one
      // line above going nowhere anybody can see. The copy that is running may have its icon
      // hidden, so it is asked to open its menu rather than the person being told where to look.
      DistributedNotificationCenter.default().postNotificationName(
        Self.revealNotification, object: nil, userInfo: nil, deliverImmediately: true
      )
      exit(0)
    }
    controller = runtime
    installStatusItem()
    panelStore.perform = { [weak self] action in self?.perform(action) }
    ShortcutBridge.panel = { [weak self] in self?.controller?.panel ?? .placeholder }
    ShortcutBridge.perform = { [weak self] action in self?.perform(action) }
    let statusMenu = StatusMenu(store: panelStore) { [weak self] action in
      self?.perform(action)
    }
    self.statusMenu = statusMenu
    statusItem?.menu = statusMenu.menu
    // An icon shown only because the app was opened again goes back into hiding with its menu,
    // and never while the menu is open. Not before the next turn of the run loop: the item that
    // was clicked acts after the menu closes, and turning the option off there should not blink
    // the icon away first.
    statusMenu.onOpen = { [weak self] in self?.menuOpen = true }
    statusMenu.onClose = { [weak self] in
      self?.menuOpen = false
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.hideRevealedIcon() }
      }
    }
    DistributedNotificationCenter.default().addObserver(
      forName: Self.revealNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.revealMenu() }
    }
    runtime.onMenuChanged = { [weak self] in self?.refreshInterface() }
    runtime.onOpenDiagnostics = { [weak self] in self?.showDiagnostics() }
    // Only the menu bar app updates. A guardian or worker is this same bundle and must never
    // show a window or replace the app underneath the process that started it.
    let updater = Updater()
    self.updater = updater
    runtime.onCheckForUpdates = { updater.checkForUpdates() }
    // A display that vanishes can take the menu's own window with it, so close rather than ride
    // out a reconfiguration this app may itself have caused. Only an actual change to the set of
    // displays counts: this notification also fires for every visibleFrame change.
    knownScreens = Self.screenIDs()
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let current = Self.screenIDs()
        guard current != self.knownScreens else { return }
        self.knownScreens = current
        self.statusMenu?.menu.cancelTracking()
      }
    }
    refreshInterface()
    if ProcessInfo.processInfo.arguments.contains("--diagnostics") {
      showDiagnostics()
    }
  }

  /// Every menu choice comes through here, so one that needs a question first cannot slip past.
  private func perform(_ action: MenuAction) {
    guard let controller else { return }
    guard controller.confirmation(for: action) != nil else {
      controller.perform(action)
      if action == .toggleMenuBarIcon, controller.panel.menuBarIcon.isOn {
        explainHiddenIcon()
      }
      return
    }
    // The cards are a view inside the menu, and clicking one leaves it open. An alert opened
    // inside the menu's tracking loop would sit behind it, so the menu closes first.
    statusMenu?.menu.cancelTracking()
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated { self?.confirm(action) }
    }
  }

  /// Asked again once the menu is gone, because the screen may have changed in between.
  private func confirm(_ action: MenuAction) {
    guard let controller else { return }
    guard let question = controller.confirmation(for: action) else {
      controller.perform(action)
      return
    }
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = question.title
    alert.informativeText = question.detail
    alert.addButton(withTitle: question.confirm)
    alert.addButton(withTitle: "Cancel")
    alert.showsSuppressionButton = question.dismissible
    alert.suppressionButton?.title = "Don't warn me again"
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    if question.dismissible, alert.suppressionButton?.state == .on {
      controller.dismissFreezeWarning()
    }
    controller.perform(action)
  }

  /// Said every time the icon is hidden, because nothing left on screen says how to undo it.
  /// Shown once the menu is gone, as an alert inside its tracking loop would sit behind it.
  private func explainHiddenIcon() {
    hideTimer?.invalidate()
    iconRevealed = false
    applyIconVisibility()
    statusMenu?.menu.cancelTracking()
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "The menu bar icon is hidden"
        alert.informativeText =
          "SoloDisplay keeps running. Open SoloDisplay again to get its menu back. "
            + "The icon also returns on its own when something needs your attention."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Icon")
        guard alert.runModal() == .alertSecondButtonReturn, let self,
              self.controller?.panel.menuBarIcon.isOn == true
        else { return }
        self.controller?.perform(.toggleMenuBarIcon)
      }
    }
  }

  /// Opening the app while it runs is the way back to a hidden icon, so it opens the menu.
  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    revealMenu()
    return false
  }

  private func revealMenu() {
    guard controller != nil, statusItem != nil else { return }
    iconRevealed = true
    applyIconVisibility()
    revealedUntil = Date().addingTimeInterval(Self.revealGrace)
    // Covers a menu that cannot open at all, as over a full screen app.
    scheduleHide(after: Self.revealGrace)
    clickWhenPlaced(polls: 0, last: nil)
  }

  /// Clicks the icon once the menu bar has put it in place. A newly shown icon starts at the
  /// screen's left edge and is moved into the menu bar a few dozen milliseconds later, and a menu
  /// opened before then opens at the left edge. After half a second it clicks anyway.
  ///
  /// From a timer, not the main queue: the menu stays open inside whatever opened it, and inside
  /// a main queue block no other main actor work runs until it closes, so a display change could
  /// not report back.
  private func clickWhenPlaced(polls: Int, last: NSRect?) {
    clickTimer?.invalidate()
    guard let button = statusItem?.button, let window = button.window else { return }
    let frame = window.frame
    if polls >= 25 || (frame == last && Self.inMenuBar(window)) {
      button.performClick(nil)
      return
    }
    let timer = Timer(timeInterval: 0.02, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.clickWhenPlaced(polls: polls + 1, last: frame) }
    }
    RunLoop.main.add(timer, forMode: .default)
    clickTimer = timer
  }

  /// Centered in the strip above the screen's usable area, where the menu bar is, or above it
  /// while the menu bar is hidden. The button's window reaches a little past the menu bar.
  private static func inMenuBar(_ window: NSWindow) -> Bool {
    guard let screen = window.screen, window.frame.height > 0 else { return false }
    return window.frame.midY >= screen.visibleFrame.maxY
  }

  /// Hides a revealed icon once its menu is closed and its couple of seconds are up.
  private func hideRevealedIcon() {
    guard iconRevealed, !menuOpen else { return }
    let remaining = revealedUntil.timeIntervalSinceNow
    guard remaining <= 0 else {
      scheduleHide(after: remaining)
      return
    }
    hideTimer?.invalidate()
    iconRevealed = false
    applyIconVisibility()
  }

  private func scheduleHide(after delay: TimeInterval) {
    hideTimer?.invalidate()
    hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.hideRevealedIcon() }
    }
  }

  /// Hidden only by choice, and never while the icon is the one place a problem shows.
  private func applyIconVisibility() {
    guard let controller, let statusItem else { return }
    let panel = controller.panel
    let visible = !panel.menuBarIcon.isOn || iconRevealed || panel.glyph == .attention
    if statusItem.isVisible != visible {
      statusItem.isVisible = visible
    }
  }

  private func startGuardian() {
    NSApp.setActivationPolicy(.prohibited)
    guard let executable = Bundle.main.executableURL else { exit(70) }
    let runtime = GuardianRuntime(
      executable: executable,
      diagnostics: .init(role: .guardian, run: operationalDiagnostics.run)
    )
    guardian = runtime
    runtime.start()
  }

  /// Normally unreachable: `SoloDisplayApp.init` runs the worker before the app starts.
  private func startWorker() {
    NSApp.setActivationPolicy(.prohibited)
    Task.detached {
      let status = DisplayWorker.run()
      fflush(stdout)
      exit(status)
    }
  }

  /// Explicitly unprotected: the read-only interface, with display control unavailable.
  private func startUnprotectedInterface() {
    NSApp.setActivationPolicy(.accessory)
    diagnostics.start()
    installStatusItem()
    let menu = NSMenu()
    menu.addItem(
      withTitle: "SoloDisplay is running read-only", action: nil, keyEquivalent: ""
    )
    menu.addItem(
      withTitle: "Turning the laptop screen off is unavailable.", action: nil, keyEquivalent: ""
    )
    menu.addItem(.separator())
    addDiagnosticsWindowItem(to: menu)
    let quit = menu.addItem(
      withTitle: "Quit SoloDisplay",
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quit.target = self
    statusItem?.menu = menu
    if ProcessInfo.processInfo.arguments.contains("--diagnostics") {
      showDiagnostics()
    }
  }

  private func installStatusItem(symbol: String = "laptopcomputer") {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: symbol, accessibilityDescription: "SoloDisplay"
    )
    item.button?.toolTip = "SoloDisplay"
    statusItem = item
  }

  /// The whole point of living in the menu bar is being readable without being opened, so the
  /// icon carries the state and the description carries the same words the menu would use.
  private func applyGlyph(_ glyph: MenuGlyph, description: String) {
    guard let button = statusItem?.button else { return }
    if glyph != lastGlyph {
      lastGlyph = glyph
      button.image = NSImage(
        systemSymbolName: glyph.symbolName, accessibilityDescription: description
      )
    }
    button.image?.accessibilityDescription = description
    button.toolTip = description
    button.appearsDisabled = glyph.dimmed
  }

  /// The controller drives this whenever what the interface would say has changed. It is the
  /// only place the icon and the panel are updated, so the two cannot disagree.
  private func refreshInterface() {
    guard let controller else { return }
    let panel = controller.panel
    applyGlyph(panel.glyph, description: panel.statusDescription)
    applyIconVisibility()
    panelStore.update(panel)
    statusMenu?.update(panel)
  }

  private static func screenIDs() -> Set<CGDirectDisplayID> {
    Set(NSScreen.screens.compactMap {
      $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    })
  }

  private func addDiagnosticsWindowItem(to menu: NSMenu) {
    let show = menu.addItem(
      withTitle: "Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: ""
    )
    show.target = self
    show.isEnabled = true
  }

  @objc private func showDiagnostics() {
    if diagnosticsWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false
      )
      window.title = "SoloDisplay Display Diagnostics"
      window.contentViewController = NSHostingController(
        rootView: ContentView(model: diagnostics) { [weak self] in
          self?.controller?.perform(.exportDiagnostics)
        }
      )
      window.isReleasedWhenClosed = false
      window.center()
      diagnosticsWindow = window
      diagnostics.start()
    }
    diagnosticsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  /// Quitting never waits. A guardian that is running restores the laptop screen once this
  /// process is gone.
  func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
    controller?.beginQuit()
    return .terminateNow
  }

  func applicationWillTerminate(_: Notification) {
    controller?.stop()
    diagnostics.stop()
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
    }
  }
}
