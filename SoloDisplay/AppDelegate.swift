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
  private var panelMenu: NSMenu?
  private var panelHosting: NSHostingView<MenuPanelView>?
  private let panelStore = MenuPanelStore()
  private var knownScreens: Set<CGDirectDisplayID> = []
  private let operationalDiagnostics = OperationalLogger(role: .bootstrap)

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
      exit(0)
    }
    controller = runtime
    installStatusItem()
    attachPanel()
    panelStore.perform = { [weak self] action in self?.performPanelAction(action) }
    runtime.onMenuChanged = { [weak self] in self?.refreshInterface() }
    runtime.onOpenDiagnostics = { [weak self] in self?.showDiagnostics() }
    // A display that vanishes can take the panel's own window with it, so close rather than ride
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
        self.panelMenu?.cancelTracking()
      }
    }
    refreshInterface()
    if ProcessInfo.processInfo.arguments.contains("--diagnostics") {
      showDiagnostics()
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
    panelStore.update(panel)
  }

  private static func screenIDs() -> Set<CGDirectDisplayID> {
    Set(NSScreen.screens.compactMap {
      $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    })
  }

  private func attachPanel() {
    guard let button = statusItem?.button else { return }
    button.target = self
    button.action = #selector(statusItemClicked)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
  }

  @objc private func statusItemClicked() {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showFallbackMenu()
      return
    }
    togglePanel()
  }

  /// The panel is a view inside a real `NSMenu` rather than an `NSPopover`. Only a menu counts as
  /// attached to the menu bar, which keeps an auto-hidden menu bar down while the panel is open.
  private func togglePanel() {
    guard let statusItem, let button = statusItem.button else { return }
    if panelMenu != nil {
      panelMenu?.cancelTracking()
      return
    }
    let hosting = NSHostingView(rootView: MenuPanelView(store: panelStore))
    // Sized from the content, so the panel's padding does not drift as the text changes.
    hosting.sizingOptions = [.intrinsicContentSize]
    hosting.translatesAutoresizingMaskIntoConstraints = false
    hosting.widthAnchor.constraint(equalToConstant: 300).isActive = true
    panelHosting = hosting

    let item = NSMenuItem()
    item.view = hosting
    let menu = NSMenu()
    menu.addItem(item)
    menu.delegate = self
    panelMenu = menu

    // Attaching the menu makes this click open it. Leaving it attached afterwards would suppress
    // the button action that the panel is opened by in the first place.
    statusItem.menu = menu
    button.performClick(nil)
    statusItem.menu = nil
  }

  private func showFallbackMenu() {
    guard let statusItem else { return }
    let menu = NSMenu()
    addDiagnosticsWindowItem(to: menu)
    menu.addItem(.separator())
    let quit = menu.addItem(
      withTitle: "Quit SoloDisplay", action: #selector(quit), keyEquivalent: "q"
    )
    quit.target = self
    menu.autoenablesItems = false
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    // Leaving the menu attached would suppress the button action the panel is opened by.
    statusItem.menu = nil
  }

  private func performPanelAction(_ action: MenuAction) {
    // Commands dismiss, the way picking from a menu does. Choosing an arrangement does not: the
    // tile and the line underneath are the only confirmation the choice landed.
    switch action {
    case .quit, .openDisplayMonitor, .exportDiagnostics:
      panelMenu?.cancelTracking()
    case .selectAllMonitors, .selectExternalOnly, .toggleLaunchAtLogin, .retryRecovery:
      break
    }
    controller?.perform(action)
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

extension AppDelegate: NSMenuDelegate {
  /// Tracking ends however the menu was dismissed, so this is the single place the panel is let
  /// go of, rather than each of the routes that can close it.
  func menuDidClose(_: NSMenu) {
    panelMenu = nil
    panelHosting = nil
  }
}
