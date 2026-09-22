import AppKit
import Foundation
import ServiceManagement
import SoloDisplayCore
import SoloDisplayPlatform
import UniformTypeIdentifiers

/// The menu-bar app. It decides through the production coordinator, hands every display change
/// to a one-shot worker, and has a guardian running before the laptop screen is ever turned off.
@MainActor
final class ControllerRuntime: CoordinatorDelegate {
  private var instanceLock: SessionWriterLock?
  private var coordinator: ProductionCoordinator?
  private let preferencesStore: PreferencesStore?
  private var preferences: Preferences
  private var drainTimer: Timer?
  private var monitor: DisplayEventMonitor?
  private var subscriptions: [(NotificationCenter, NSObjectProtocol)] = []
  private var previous: Presentation?
  private let session = UUID().uuidString
  private let diagnostics: OperationalLogger
  private let exporter: DiagnosticsExporter
  private var exporting = false
  private var exportAlert: NSAlert?
  private let brightnessKeys = BrightnessKeys()

  private(set) var panel: MenuPanel = .placeholder
  var onMenuChanged: (() -> Void)?
  var onOpenDiagnostics: (() -> Void)?
  var onCheckForUpdates: (() -> Void)?

  init(
    diagnostics: OperationalLogger = .init(role: .app),
    exporter: DiagnosticsExporter = .init()
  ) {
    self.diagnostics = diagnostics
    self.exporter = exporter
    preferencesStore = try? PreferencesStore()
    preferences = preferencesStore?.load() ?? .init()
  }

  // MARK: - Lifecycle

  /// False when another SoloDisplay already runs in this login session.
  func start() -> Bool {
    diagnostics.started()
    // The registration lives in the system and can be revoked there, so the system is the
    // authority rather than the preferences file.
    let registered = SMAppService.mainApp.status == .enabled
    if preferences.launchAtLogin != registered {
      mutatePreferences { $0.launchAtLogin = registered }
    }
    brightnessKeys.onChange = { [weak self] in self?.refreshMenu() }
    brightnessKeys.setEnabled(preferences.brightnessKeys, askForPermission: false)
    let observer = LivePlatformObserver()
    let reading = observer.read()
    guard let loginID = reading.loginID else {
      diagnostics.emit(.startupFailed, reason: .missingSession)
      refreshMenu()
      return true
    }
    do {
      instanceLock = try SessionWriterLock(loginID: loginID, name: "instance")
    } catch WriterLockError.alreadyHeld {
      diagnostics.emit(.exitRequested, reason: .alreadyRunning)
      return false
    } catch {
      diagnostics.emit(.instanceLockUnavailable)
    }
    guard let store = preferencesStore, let journal = try? ProductionJournalStore(),
          let executable = Bundle.main.executableURL
    else {
      diagnostics.emit(.startupFailed, reason: .journalUnavailable)
      refreshMenu()
      return true
    }
    // Only External Only turns anything off. Older preference files may still say manual.
    let mode: Mode = preferences.mode == .automatic ? .automatic : .automaticPaused
    let resolved = ProductionCoordinator.resolveRecord(journal, reading: reading)
    var state = ControllerState(mode: mode, record: resolved.target)
    state.recordBlocked = resolved.blocked
    // Monitors a previous run turned off are an obligation to give back, whatever else is true.
    // Turning a monitor on is always safe, so they are carried in and restored, never assumed.
    let suppression = try? ExternalSuppressionStore()
    state.suppressed = ProductionCoordinator.resolveSuppression(
      suppression, reading: reading
    )
    let coordinator = ProductionCoordinator(
      state: state, clock: MonotonicClock(), observer: observer,
      writer: WorkerDisplayWriter(executable: executable), ownership: journal,
      preferences: store, guardian: GuardianProcess(executable: executable), delegate: self,
      inputSources: LiveInputSourceObserver(), suppression: suppression,
      session: session, diagnostics: diagnostics
    )
    self.coordinator = coordinator
    coordinator.start()
    startObservingPlatform()
    // A fallback for display callbacks, which normally arrive through the change handler.
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.drainDisplayEvents() }
    }
    RunLoop.main.add(timer, forMode: .common)
    drainTimer = timer
    refreshMenu()
    return true
  }

  /// Quitting needs no waiting. If the laptop screen is off, or a monitor is, the guardian sees
  /// this process go and turns them back on, the same path as a crash.
  func beginQuit() {
    diagnostics.emit(.exitRequested, session: session, reason: .userQuit) {
      $0.panelOff = coordinator?.presentation.panelOff
    }
  }

  func stop() {
    drainTimer?.invalidate()
    drainTimer = nil
    coordinator?.stop()
    brightnessKeys.stop()
    for (center, token) in subscriptions {
      center.removeObserver(token)
    }
    subscriptions.removeAll()
    monitor = nil
    instanceLock?.release()
  }

  private func startObservingPlatform() {
    let monitor = DisplayEventMonitor()
    self.monitor = monitor
    // Settling is timed from these reports, so they are delivered now rather than at the next poll.
    monitor.setChangeHandler { [weak self] in
      Task { @MainActor in self?.drainDisplayEvents() }
    }
    subscribe(.default, NSApplication.didChangeScreenParametersNotification)
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
      NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
      NSWorkspace.sessionDidBecomeActiveNotification,
      NSWorkspace.sessionDidResignActiveNotification
    ] {
      subscribe(workspace, name)
    }
  }

  /// Notifications and display callbacks only ever queue work. They never configure a display.
  private func subscribe(_ center: NotificationCenter, _ name: Notification.Name) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let coordinator = self.coordinator else { return }
        switch name {
        case NSWorkspace.willSleepNotification:
          self.diagnostics.emit(.suspended, session: self.session, reason: .workspaceSleep)
          coordinator.send(.willSleep)
        case NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification:
          self.diagnostics.emit(.resumed, session: self.session, reason: .workspaceWake)
          coordinator.send(.waking)
        default:
          let reason: OperationalEvent.Reason? = switch name {
          case NSWorkspace.screensDidSleepNotification: .workspaceScreenSleep
          case NSWorkspace.sessionDidBecomeActiveNotification: .workspaceSessionActive
          case NSWorkspace.sessionDidResignActiveNotification: .workspaceSessionInactive
          default: nil
          }
          if let reason {
            self.diagnostics.emit(.lifecycleReconciled, reason: reason)
          }
          coordinator.platformDidChange()
        }
      }
    }
    subscriptions.append((center, token))
  }

  private func drainDisplayEvents() {
    guard let batch = monitor?.drain(), !batch.events.isEmpty || batch.dropped > 0 else { return }
    // A lost report could have been the one that finished a reconfiguration, so assume it did not.
    let inProgress = batch.dropped > 0 || batch.events.last?.beginsConfiguration == true
    coordinator?.send(.displayReconfigured(inProgress: inProgress))
    coordinator?.platformDidChange()
  }

  // MARK: - Coordinator delegate

  func coordinator(_ source: ProductionCoordinator, didUpdate presentation: Presentation) {
    if previous != presentation {
      diagnostics.emit(.stateChanged, session: session) {
        $0.mode = source.state.mode
        $0.trouble = presentation.trouble
        $0.unavailability = presentation.unavailability
        $0.panelOff = presentation.panelOff
        $0.working = presentation.working
        $0.failures = source.state.failures
      }
    }
    previous = presentation
    brightnessKeys.setActive(presentation.panelOff)
    refreshMenu()
  }

  // MARK: - Menu

  var presentation: Presentation {
    coordinator?.presentation ?? .init(unavailability: .notRunning)
  }

  private func refreshMenu() {
    let next = MenuModel.panel(
      presentation, launchAtLogin: preferences.launchAtLogin,
      brightnessKeys: preferences.brightnessKeys,
      brightnessNeedsPermission: brightnessKeys.needsPermission
    )
    // Redrawing an identical panel would move things under the pointer for no reason.
    guard next != panel else { return }
    panel = next
    onMenuChanged?()
  }

  func perform(_ action: MenuAction) {
    diagnostics.emit(.action, session: session) {
      $0.action = OperationalEvent.Action(rawValue: action.rawValue)
    }
    switch action {
    // Both tiles are stored intents. External Only is off whenever a monitor is there for it.
    case .selectAllMonitors: coordinator?.send(.selectMode(.automaticPaused))
    case .selectExternalOnly: coordinator?.send(.selectMode(.automatic))
    case .retryRecovery: coordinator?.send(.retry)
    case .toggleLaunchAtLogin: toggleLaunchAtLogin()
    case .toggleBrightnessKeys:
      mutatePreferences { $0.brightnessKeys.toggle() }
      brightnessKeys.setEnabled(preferences.brightnessKeys, askForPermission: true)
    case .checkForUpdates: onCheckForUpdates?()
    case .openDisplayMonitor: onOpenDiagnostics?()
    case .exportDiagnostics: exportDiagnostics()
    case .quit: NSApp.terminate(nil)
    }
    // The coordinator persists the mode through its own effect. Re-read rather than write a
    // cached copy back, so nothing here can clobber another field.
    preferences = preferencesStore?.load() ?? preferences
    refreshMenu()
  }

  private func mutatePreferences(_ change: (inout Preferences) -> Void) {
    guard let store = preferencesStore else {
      change(&preferences)
      return
    }
    preferences = (try? store.update(change)) ?? preferences
  }

  private func toggleLaunchAtLogin() {
    let service = SMAppService.mainApp
    let wanted = !preferences.launchAtLogin
    do {
      if wanted {
        try service.register()
      } else {
        try service.unregister()
      }
      mutatePreferences { $0.launchAtLogin = wanted }
    } catch {
      // Record the real state, never the requested one.
      let actual = service.status == .enabled
      mutatePreferences { $0.launchAtLogin = actual }
    }
  }

  /// Sanitized, bounded, local. Nothing is uploaded.
  private func exportDiagnostics() {
    guard !exporting else { return }
    exporting = true
    diagnostics.emit(.exportRequested)
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "solodisplay-diagnostics.json"
    panel.allowedContentTypes = [.json]
    panel.begin { [weak self] response in
      MainActor.assumeIsolated {
        guard let self else { return }
        guard response == .OK, let url = panel.url else {
          self.exporting = false
          return
        }
        let exporter = self.exporter
        let snapshot = self.coordinator.map {
          DiagnosticsSnapshot($0.state, at: MonotonicClock().now())
        }
        // swiftformat:disable redundantSelf
        Task { @MainActor [weak self] in
          let result = await Task.detached {
            do {
              let data = try exporter.collect(snapshot: snapshot)
              do { try exporter.write(data, to: url) } catch {
                return ExportResult.failure(.exportWriting)
              }
              let document = try JSONDecoder().decode(DiagnosticsDocument.self, from: data)
              return ExportResult.success(document.diagnostics.history.status)
            } catch { return ExportResult.failure(.exportEncoding) }
          }.value
          guard let self else { return }
          self.exporting = false
          switch result {
          case let .failure(reason):
            self.diagnostics.emit(.exportFailed, reason: reason, succeeded: false)
            self.showExportMessage(
              "Diagnostics could not be saved",
              reason == .exportWriting
                ? "Try another location. No diagnostics were uploaded."
                : "SoloDisplay could not prepare the diagnostic snapshot. Please report this export error. Nothing was uploaded."
            )
          case let .success(status):
            self.diagnostics.emit(.exportCompleted)
            if status != .collected {
              self.showExportMessage(
                "Diagnostics saved with limited history",
                "The current state was saved, but no earlier history was available. "
                  + DiagnosticsMetadata.consoleInstructions
              )
            }
          }
        }
        // swiftformat:enable redundantSelf
      }
    }
  }

  private enum ExportResult: Sendable {
    case success(OperationalHistory.Status)
    case failure(OperationalEvent.Reason)
  }

  private func showExportMessage(_ title: String, _ message: String) {
    exportAlert?.window.close()
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    let button = alert.addButton(withTitle: "OK")
    // Do not enter a synchronous modal loop from a main-actor task.
    button.target = self
    button.action = #selector(dismissExportMessage)
    alert.layout()
    exportAlert = alert
    alert.window.makeKeyAndOrderFront(nil)
  }

  @objc private func dismissExportMessage() {
    exportAlert?.window.close()
    exportAlert = nil
  }
}
