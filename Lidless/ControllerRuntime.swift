import AppKit
import Foundation
import LidlessCore
import LidlessPlatform
import ServiceManagement
import UniformTypeIdentifiers

/// The menu-bar process. It pairs with its recovery helper, holds exclusive writer ownership
/// for the whole run, and drives the production coordinator. No path here reaches a lab command.
@MainActor
final class ControllerRuntime: ProtectionRequesting, CoordinatorDelegate {
  private let link: ProtectionLink
  private var protection: ControllerProtection
  private var writerLock: SessionWriterLock?
  private var coordinator: ProductionCoordinator?
  private var recorder: TraceRecorder
  private let preferencesStore: PreferencesStore?
  private var preferences: Preferences
  private var protectionTimer: Timer?
  private var monitor: DisplayEventMonitor?
  private var subscriptions: [(NotificationCenter, NSObjectProtocol)] = []
  /// The arm request the coordinator is waiting on. Exactly one can be outstanding.
  private var pendingArm: UInt64?
  private var previous: Presentation?
  private var lockUnavailable = false
  private var exiting = false
  /// Contact with the supervising helper is gone. Without it there is no protection, so this
  /// process finishes any restoration it owes and then stops rather than lingering unsupervised.
  private var helperLost = false

  private(set) var items: [MenuItem] = []
  var onMenuChanged: (() -> Void)?

  init(link: ProtectionLink) {
    self.link = link
    protection = .init(session: UUID().uuidString, at: MonotonicClock().now())
    preferencesStore = try? PreferencesStore()
    preferences = preferencesStore?.load() ?? .init()
    recorder = .init()
  }

  // MARK: - Lifecycle

  func start() {
    let validation = (try? BackendValidationStore())?.current(
      symbolName: PrivateDisplayAPI().symbolName)
    let observer = LivePlatformObserver(validation: validation)
    let reading = observer.read()
    if let loginID = reading.loginID {
      writerLock = try? SessionWriterLock(loginID: loginID)
    }
    lockUnavailable = writerLock == nil
    note(
      "login=\(reading.loginID.map(String.init) ?? "nil") lock=\(writerLock != nil) validation=\(validation != nil)")

    var state = ControllerState(mode: preferences.mode)
    // Automatic mode resumes from preferences, but a paused choice stays paused across restarts.
    if let store = preferencesStore, let journal = try? ProductionJournalStore() {
      recorder = .init(initial: state)
      let coordinator = ProductionCoordinator(
        state: state, clock: MonotonicClock(), observer: observer, writer: LiveDisplayWriter(),
        ownership: journal, preferences: store, protection: self, delegate: self)
      self.coordinator = coordinator
      coordinator.start()
    } else {
      state.fault = .journalFailed
      recorder = .init(initial: state)
    }
    apply(protection.receive(.start, at: MonotonicClock().now()))
    startObservingPlatform()
    protectionTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pumpProtection() }
    }
    refreshMenu()
  }

  /// Quit asks for restoration first and only lets the app exit once nothing is unresolved.
  /// If this process dies anyway, the helper still holds recovery responsibility.
  func beginQuit() -> Bool {
    guard let coordinator else { return true }
    exiting = true
    coordinator.send(.quit)
    return coordinator.state.ownership == nil && !coordinator.state.pendingClear
  }

  func stop() {
    protectionTimer?.invalidate()
    protectionTimer = nil
    coordinator?.stop()
    for (center, token) in subscriptions { center.removeObserver(token) }
    subscriptions.removeAll()
    monitor = nil
    apply(protection.receive(.shutdown, at: MonotonicClock().now()))
    link.stop()
    writerLock?.release()
  }

  private func startObservingPlatform() {
    let monitor = DisplayEventMonitor()
    self.monitor = monitor
    subscribe(.default, NSApplication.didChangeScreenParametersNotification)
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
      NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
      NSWorkspace.sessionDidBecomeActiveNotification,
      NSWorkspace.sessionDidResignActiveNotification,
    ] { subscribe(workspace, name) }
  }

  /// Notifications and display callbacks only ever queue work. They never configure a display.
  private func subscribe(_ center: NotificationCenter, _ name: Notification.Name) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let coordinator = self.coordinator else { return }
        switch name {
        case NSWorkspace.willSleepNotification: coordinator.send(.willSleep)
        case NSWorkspace.didWakeNotification: coordinator.send(.waking)
        default: coordinator.platformDidChange()
        }
      }
    }
    subscriptions.append((center, token))
  }

  private func pumpProtection() {
    let now = MonotonicClock().now()
    do {
      while let message = try link.poll() {
        apply(protection.receive(.received(message), at: now))
      }
    } catch {
      apply(protection.receive(.peerFailed(.disconnected), at: now))
    }
    apply(protection.receive(.tick, at: now))
    if let batch = monitor?.drain(), !batch.events.isEmpty || batch.dropped > 0 {
      coordinator?.platformDidChange()
    }
  }

  // MARK: - Protection

  private var paired = false

  private func apply(_ outputs: [ControllerProtection.Output]) {
    for output in outputs {
      switch output {
      case .send(let message): try? link.send(message)
      case .protectionEstablished:
        if let id = pendingArm {
          pendingArm = nil
          coordinator?.send(.protectionArmed(operationID: id, succeeded: true))
        }
      case .protectionLost:
        if let id = pendingArm {
          pendingArm = nil
          coordinator?.send(.protectionArmed(operationID: id, succeeded: false))
        }
        paired = false
        helperLost = true
        coordinator?.send(.protectionAvailable(false))
        stopIfNothingIsOwed()
      }
    }
    // Pairing, not the lease, is what makes disabling available at rest.
    let pairedNow =
      protection.phase == .paired || protection.phase == .arming
      || protection.phase == .protected
    if pairedNow != paired {
      note("protection phase=\(protection.phase) paired=\(pairedNow) lockUnavailable=\(lockUnavailable)")
      paired = pairedNow
      coordinator?.send(.protectionAvailable(pairedNow && !lockUnavailable))
    }
  }

  func arm(operationID: UInt64, ownership: Ownership) {
    pendingArm = operationID
    apply(protection.receive(.arm(ownership), at: MonotonicClock().now()))
  }

  func release() {
    pendingArm = nil
    apply(protection.receive(.release, at: MonotonicClock().now()))
  }

  func noteOperation(_ progress: OperationProgress?) { protection.note(progress: progress) }

  // MARK: - Coordinator delegate

  func coordinator(_ coordinator: ProductionCoordinator, didUpdate presentation: Presentation) {
    // Automatic mode unlocks only after this installation has actually turned the panel off in
    // manual mode and seen it verified back on. Offering it earlier would be asking for trust
    // in a path nothing has exercised here.
    if previous?.panelOwned == true, !presentation.panelOwned, !presentation.pendingRecovery,
      presentation.fault == nil, presentation.mode == .manual, !preferences.manualPathValidated
    {
      mutatePreferences { $0.manualPathValidated = true }
    }
    previous = presentation
    refreshMenu()
    stopIfNothingIsOwed()
  }

  /// Leaving an unsupervised controller running would hold the writer lock and block a fresh
  /// pair from starting, so it exits once it owes nothing.
  private func stopIfNothingIsOwed() {
    guard helperLost, !exiting else { return }
    let state = coordinator?.state
    guard state == nil || (state?.ownership == nil && state?.pendingClear == false) else { return }
    exiting = true
    NSApp.terminate(nil)
  }

  func coordinator(_ coordinator: ProductionCoordinator, didRecord event: RecordedEvent) {
    try? recorder.append(event)
  }

  func coordinatorIsReadyToExit(_ coordinator: ProductionCoordinator) {
    guard exiting else { return }
    exiting = false
    NSApp.reply(toApplicationShouldTerminate: true)
  }

  // MARK: - Menu

  private var automaticAvailable: Bool { preferences.manualPathValidated }

  var presentation: Presentation {
    coordinator?.presentation
      ?? .init(
        mode: preferences.mode, manualRequestActive: false, panelOwned: false,
        operationInFlight: false, pendingRecovery: false, fault: .journalFailed,
        unavailability: .faulted)
  }

  private func refreshMenu() {
    var current = presentation
    if lockUnavailable, current.unavailability == nil {
      current.unavailability = .noRecoveryHelper
    }
    items = MenuModel.items(
      current, launchAtLogin: preferences.launchAtLogin, automaticAvailable: automaticAvailable)
    onMenuChanged?()
  }

  func perform(_ action: MenuAction) {
    let coordinator = coordinator
    switch action {
    case .selectManual: coordinator?.send(.selectMode(.manual))
    case .selectAutomatic:
      guard automaticAvailable else { return }
      coordinator?.send(.selectMode(.automatic))
    case .turnInternalOff: coordinator?.send(.manualOff)
    case .turnInternalOn, .keepInternalOn: coordinator?.send(.keepOn)
    case .resumeAutomatic: coordinator?.send(.selectMode(.automatic))
    case .retryRecovery: coordinator?.send(.retry)
    case .toggleLaunchAtLogin: toggleLaunchAtLogin()
    case .exportDiagnostics: exportDiagnostics()
    case .quit: NSApp.terminate(nil)
    }
    // The coordinator persists the mode through its own effect. Re-read rather than write a
    // cached copy back, so nothing here can clobber another field.
    preferences = preferencesStore?.load() ?? preferences
    refreshMenu()
  }

  private func note(_ message: String) {
    FileHandle.standardError.write(Data("Lidless controller: \(message)\n".utf8))
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
      if wanted { try service.register() } else { try service.unregister() }
      mutatePreferences { $0.launchAtLogin = wanted }
    } catch {
      // Record the real state, never the requested one.
      let actual = service.status == .enabled
      mutatePreferences { $0.launchAtLogin = actual }
    }
  }

  /// Sanitized, bounded, local. Nothing is uploaded and no raw lab log is offered as an export.
  private func exportDiagnostics() {
    guard let data = try? recorder.exportSanitized() else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "lidless-diagnostics.json"
    panel.allowedContentTypes = [.json]
    panel.begin { response in
      MainActor.assumeIsolated {
        guard response == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: [.atomic])
      }
    }
  }
}
