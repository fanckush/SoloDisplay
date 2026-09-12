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
  private var helper: HelperRuntime?
  private var controller: ControllerRuntime?
  private var lastGlyph: MenuGlyph?
  private var panelMenu: NSMenu?
  private var panelHosting: NSHostingView<MenuPanelView>?
  private let panelStore = MenuPanelStore()
  private var knownScreens: Set<CGDirectDisplayID> = []
  private let operationalDiagnostics = OperationalLogger(role: .bootstrap)

  func applicationDidFinishLaunching(_: Notification) {
    // Unit tests exercise the model without starting the platform observer.
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    // A write to a peer that has gone away must surface as an error on the link, not kill this
    // process. Without this the controller dies mid-restoration when the helper disappears.
    signal(SIGPIPE, SIG_IGN)
    let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
    if arguments.contains(where: { $0.hasPrefix("--lab-") }) {
      runLabCommand(arguments)
      return
    }
    operationalDiagnostics.started()
    do {
      let role = try ProductionLaunch.role(
        arguments: arguments, pipedStandardStreams: ProductionLaunch.standardStreamsArePipes()
      )
      switch role {
      case .helper: startHelper()
      case .controller: startController()
      case .recoveryWorker: startRecoveryWorker()
      case .unprotected: startUnprotectedInterface()
      }
    } catch {
      operationalDiagnostics.emit(
        .startupFailed, reason: .invalidLaunch,
        errorCode: (error as NSError).code
      )
      operationalDiagnostics.emit(.exitRequested, reason: .invalidLaunch)
      FileHandle.standardError.write(Data("SoloDisplay: \(error)\n".utf8))
      exit(64)
    }
  }

  /// A normal launch becomes the supervising process and starts its own controller child.
  private func startHelper() {
    guard let executable = Bundle.main.executableURL else {
      operationalDiagnostics.emit(.startupFailed, reason: .missingExecutable)
      operationalDiagnostics.emit(.exitRequested, reason: .missingExecutable)
      FileHandle.standardError.write(
        Data("SoloDisplay cannot resolve its own executable and will not start.\n".utf8)
      )
      exit(70)
    }
    guard let store = try? ProductionJournalStore() else {
      operationalDiagnostics.emit(.startupFailed, reason: .journalUnavailable)
      operationalDiagnostics.emit(.exitRequested, reason: .journalUnavailable)
      FileHandle.standardError.write(
        Data("SoloDisplay cannot open its recovery store and will not start.\n".utf8)
      )
      exit(70)
    }
    NSApp.setActivationPolicy(.prohibited)
    let runtime = HelperRuntime(
      executable: executable, store: store,
      diagnostics: .init(role: .helper, run: operationalDiagnostics.run)
    )
    runtime.onInterfaceStateChanged = { [weak self] state in
      self?.updateHelperInterface(state)
    }
    helper = runtime
    Task { @MainActor in await runtime.start() }
  }

  private func startController() {
    NSApp.setActivationPolicy(.accessory)
    let runtime = ControllerRuntime(
      link: ProtectionLink(input: .standardInput, output: .standardOutput),
      diagnostics: .init(role: .controller, run: operationalDiagnostics.run)
    )
    controller = runtime
    installStatusItem()
    attachPanel()
    panelStore.perform = { [weak self] action in self?.performPanelAction(action) }
    runtime.onMenuChanged = { [weak self] in self?.refreshInterface() }
    runtime.onOpenDiagnostics = { [weak self] in self?.showDiagnostics() }
    // A display that vanishes can take the panel's own window with it, so close rather than ride
    // out a reconfiguration this app may itself have caused. Only an actual change to the set of
    // displays counts: this notification also fires for every visibleFrame change, which includes
    // the menu bar revealing itself over a full-screen app, and closing on that dismissed the
    // panel the moment someone moved the pointer up to reach it.
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
    runtime.start()
    refreshInterface()
    if ProcessInfo.processInfo.arguments.contains("--diagnostics") {
      showDiagnostics()
    }
  }

  private func startRecoveryWorker() {
    NSApp.setActivationPolicy(.prohibited)
    Task.detached {
      let status = RecoveryWorker.run()
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
      withTitle: "SoloDisplay is running without its recovery helper", action: nil,
      keyEquivalent: ""
    )
    menu.addItem(
      withTitle: "Turning the internal display off is unavailable.", action: nil, keyEquivalent: ""
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

  private func updateHelperInterface(_ state: HelperInterfaceState) {
    switch state {
    case .hidden:
      if let statusItem {
        NSStatusBar.system.removeStatusItem(statusItem)
      }
      statusItem = nil
      NSApp.setActivationPolicy(.prohibited)
    case let .recovering(detail), let .blocked(detail):
      NSApp.setActivationPolicy(.accessory)
      if statusItem == nil {
        installStatusItem(symbol: "exclamationmark.triangle")
      }
      let menu = NSMenu()
      let title = state.isRecovering
        ? "Internal display recovery in progress"
        : "Internal display recovery needs attention"
      let heading = menu.addItem(
        withTitle: title, action: nil, keyEquivalent: ""
      )
      heading.isEnabled = false
      let explanation = menu.addItem(withTitle: detail, action: nil, keyEquivalent: "")
      explanation.isEnabled = false
      if !state.isRecovering {
        menu.addItem(.separator())
        let retry = menu.addItem(
          withTitle: "Retry Recovery", action: #selector(retryHelperRecovery), keyEquivalent: "r"
        )
        retry.target = self
      }
      menu.addItem(.separator())
      addDiagnosticsWindowItem(to: menu)
      menu.autoenablesItems = false
      statusItem?.menu = menu
    }
  }

  @objc private func retryHelperRecovery() {
    helper?.retryRecovery()
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

  /// The panel is a view inside a real `NSMenu` rather than an `NSPopover`.
  ///
  /// Only a menu counts as attached to the menu bar as far as the system is concerned. While one
  /// tracks, macOS holds an auto-hidden menu bar down, which is what makes the native extras feel
  /// the way they do over a full-screen app. A popover is only a window anchored near the status
  /// item, so the bar slid back up and dismissed the panel with it, and keeping it alive meant
  /// hand-rolling the dismissal that a menu already performs correctly on its own.
  private func togglePanel() {
    guard let statusItem, let button = statusItem.button else { return }
    if panelMenu != nil {
      panelMenu?.cancelTracking()
      return
    }
    let hosting = NSHostingView(rootView: MenuPanelView(store: panelStore))
    // Sized from the content rather than measured once here. The reality line runs to one, two or
    // three lines depending on what it has to say, and a menu item pinned to the height it had
    // when it opened keeps that height and lets SwiftUI centre the content inside it, which reads
    // as the panel's padding drifting every time the arrangement changes.
    hosting.sizingOptions = [.intrinsicContentSize]
    hosting.translatesAutoresizingMaskIntoConstraints = false
    // The panel is a fixed width by design; only its height is in question.
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
    // Commands dismiss, the way picking from a menu does. Choosing an arrangement does not.
    // It is a setting, and closing over it hides the tile and the line underneath that are the
    // only confirmation the choice landed. The screen-parameters observer still closes the
    // panel when the displays actually change, which is the moment a window sitting on a
    // vanishing screen would matter, and it arrives after the person has seen the change.
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

  private func runLabCommand(_ arguments: [String]) {
    #if DEBUG
      do {
        guard let command = try NativeLabCommand.parse(arguments) else {
          throw NativeLabError.refused("Missing native lab command.")
        }
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
          let status = await NativeRecoveryLab().run(command)
          fflush(stdout)
          exit(status)
        }
      } catch {
        print("Native lab arguments rejected: \(error)")
        exit(64)
      }
    #else
      print("Native hardware experiments are unavailable in Release builds.")
      exit(64)
    #endif
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

  /// Quit requests restoration first. The app exits once nothing is unresolved, and the helper
  /// keeps recovery responsibility if this process goes away before that happens.
  func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
    guard let controller else { return .terminateNow }
    return controller.beginQuit() ? .terminateNow : .terminateLater
  }

  func applicationWillTerminate(_: Notification) {
    controller?.stop()
    diagnostics.stop()
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
    }
  }
}

private extension HelperInterfaceState {
  var isRecovering: Bool {
    if case .recovering = self {
      return true
    }
    return false
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
