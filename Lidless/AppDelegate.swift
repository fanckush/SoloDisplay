import AppKit
import Darwin
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let diagnostics = DiagnosticsModel()
  private var statusItem: NSStatusItem?
  private var diagnosticsWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Unit tests exercise the model without starting the platform observer.
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--lab-") }) {
      #if DEBUG
        do {
          guard
            let command = try NativeLabCommand.parse(
              Array(ProcessInfo.processInfo.arguments.dropFirst()))
          else {
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
        return
      #else
        print("Native hardware experiments are unavailable in Release builds.")
        exit(64)
      #endif
    }
    diagnostics.start()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "laptopcomputer", accessibilityDescription: "Lidless")
    item.button?.toolTip = "Lidless: read-only development build"
    let menu = NSMenu()
    menu.addItem(withTitle: "Display control is not enabled", action: nil, keyEquivalent: "")
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
    diagnostics.stop()
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
  }
}
