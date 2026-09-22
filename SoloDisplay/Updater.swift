import AppKit
import Sparkle

/// Checks the release feed and installs updates, through Sparkle's own windows.
///
/// Installing quits this process the normal way. If the laptop screen is off, the guardian turns
/// it back on as for any quit, and the new version turns it off again once it is running.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
  private var controller: SPUStandardUpdaterController?

  override init() {
    super.init()
    // A local build is always version 1, so every published release would look newer.
    #if DEBUG
      let start = false
    #else
      let start = true
    #endif
    controller = SPUStandardUpdaterController(
      startingUpdater: start, updaterDelegate: nil, userDriverDelegate: self
    )
  }

  func checkForUpdates() {
    guard let controller, controller.updater.canCheckForUpdates else { return }
    NSApp.activate(ignoringOtherApps: true)
    controller.checkForUpdates(nil)
  }

  // MARK: - SPUStandardUserDriverDelegate

  /// A menu bar app has no Dock icon or window to come forward with, so a window Sparkle opens
  /// on its own schedule would otherwise land behind whatever is in front.
  nonisolated var supportsGentleScheduledUpdateReminders: Bool {
    true
  }

  nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate _: SUAppcastItem, state: SPUUserUpdateState
  ) {
    guard handleShowingUpdate, !state.userInitiated else { return }
    MainActor.assumeIsolated { NSApp.activate(ignoringOtherApps: true) }
  }
}
