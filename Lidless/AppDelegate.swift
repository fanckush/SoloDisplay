import AppKit
import Darwin
import Foundation
import LidlessPlatform
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let diagnostics = DiagnosticsModel()
  private var statusItem: NSStatusItem?
  private var diagnosticsWindow: NSWindow?
  private var helper: HelperRuntime?
  private var controller: ControllerRuntime?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Unit tests exercise the model without starting the platform observer.
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
    if arguments.contains(where: { $0.hasPrefix("--lab-") }) {
      runLabCommand(arguments)
      return
    }
    do {
      let role = try ProductionLaunch.role(
        arguments: arguments, pipedStandardStreams: ProductionLaunch.standardStreamsArePipes())
      switch role {
      case .helper: startHelper()
      case .controller: startController()
      case .unprotected: startUnprotectedInterface()
      }
    } catch {
      FileHandle.standardError.write(Data("Lidless: \(error)\n".utf8))
      exit(64)
    }
  }

  /// A normal launch becomes the supervising process and starts its own controller child.
  private func startHelper() {
    guard let executable = Bundle.main.executableURL else {
      FileHandle.standardError.write(
        Data("Lidless cannot resolve its own executable and will not start.\n".utf8))
      exit(70)
    }
    guard let store = try? ProductionJournalStore() else {
      FileHandle.standardError.write(
        Data("Lidless cannot open its recovery store and will not start.\n".utf8))
      exit(70)
    }
    NSApp.setActivationPolicy(.prohibited)
    let runtime = HelperRuntime(executable: executable, store: store)
    helper = runtime
    Task { @MainActor in await runtime.start() }
  }

  private func startController() {
    NSApp.setActivationPolicy(.accessory)
    let runtime = ControllerRuntime(
      link: ProtectionLink(input: .standardInput, output: .standardOutput))
    controller = runtime
    runtime.start()
    presentInterface(status: runtime.availability.explanation)
  }

  private func startUnprotectedInterface() {
    NSApp.setActivationPolicy(.accessory)
    presentInterface(
      status: "Lidless is running without its recovery helper, so display control is unavailable.")
  }

  private func presentInterface(status: String?) {
    diagnostics.start()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "laptopcomputer", accessibilityDescription: "Lidless")
    item.button?.toolTip = "Lidless: development build"
    let menu = NSMenu()
    menu.addItem(
      withTitle: status ?? "Display control is not enabled", action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    let show = menu.addItem(
      withTitle: "Display Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: "")
    show.target = self
    menu.addItem(.separator())
    let quit = menu.addItem(withTitle: "Quit Lidless", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    item.menu = menu
    statusItem = item
    if ProcessInfo.processInfo.arguments.contains("--diagnostics") { showDiagnostics() }
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
        backing: .buffered, defer: false)
      window.title = "Lidless Display Diagnostics"
      window.contentViewController = NSHostingController(rootView: ContentView(model: diagnostics))
      window.isReleasedWhenClosed = false
      window.center()
      diagnosticsWindow = window
    }
    diagnosticsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func quit() { NSApp.terminate(nil) }

  func applicationWillTerminate(_ notification: Notification) {
    // Releasing protection before exit tells the helper there is nothing left to recover.
    controller?.stop()
    diagnostics.stop()
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
  }
}
