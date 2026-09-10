import AppKit
import Darwin
import Foundation
import SoloDisplayPlatform
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let diagnostics = DiagnosticsModel()
  private var statusItem: NSStatusItem?
  private var diagnosticsWindow: NSWindow?
  private var helper: HelperRuntime?
  private var controller: ControllerRuntime?
  private var menuIsOpen = false
  private var rebuildPending = false
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
    runtime.onMenuChanged = { [weak self] in self?.rebuildMenu() }
    runtime.start()
    rebuildMenu()
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

  func menuWillOpen(_: NSMenu) {
    menuIsOpen = true
  }

  func menuDidClose(_: NSMenu) {
    menuIsOpen = false
    guard rebuildPending else { return }
    rebuildPending = false
    rebuildMenu()
  }

  private func rebuildMenu() {
    guard let controller, let statusItem else { return }
    // Never swap the menu while someone is clicking in it.
    guard !menuIsOpen else {
      rebuildPending = true
      return
    }
    let menu = NSMenu()
    for item in controller.items {
      if item.separator {
        menu.addItem(.separator())
        continue
      }
      guard let action = item.action else {
        let entry = menu.addItem(withTitle: item.title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        continue
      }
      let entry = menu.addItem(
        withTitle: item.title, action: #selector(performMenuAction(_:)),
        keyEquivalent: action == .quit ? "q" : ""
      )
      entry.target = self
      entry.isEnabled = item.enabled
      entry.state = item.checked ? .on : .off
      entry.representedObject = action.rawValue
    }
    menu.addItem(.separator())
    addDiagnosticsWindowItem(to: menu)
    // The menu is rebuilt from state, so items never disagree with what the controller believes.
    menu.autoenablesItems = false
    menu.delegate = self
    statusItem.menu = menu
  }

  private func addDiagnosticsWindowItem(to menu: NSMenu) {
    let show = menu.addItem(
      withTitle: "Display Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: ""
    )
    show.target = self
    show.isEnabled = true
  }

  @objc private func performMenuAction(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let action = MenuAction(rawValue: raw)
    else { return }
    controller?.perform(action)
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
      window.contentViewController = NSHostingController(rootView: ContentView(model: diagnostics))
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
