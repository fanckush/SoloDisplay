import AppKit
import Foundation
import ServiceManagement
import SoloDisplayCore
import SoloDisplayPlatform
import UniformTypeIdentifiers

/// The menu-bar process. It pairs with its recovery helper, holds exclusive writer ownership
/// for the whole run, and drives the production coordinator. No path here reaches a lab command.
@MainActor
final class ControllerRuntime: ProtectionRequesting, CoordinatorDelegate {
  let authorization = ProtectionAuthorization()
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
  private let diagnostics: OperationalLogger
  private let exporter: DiagnosticsExporter
  private var exporting = false
  private var exportAlert: NSAlert?
  private var activityResumeCount: UInt64 = 0

  private(set) var panel: MenuPanel = .placeholder
  var onMenuChanged: (() -> Void)?
  var onOpenDiagnostics: (() -> Void)?

  init(
    link: ProtectionLink,
    diagnostics: OperationalLogger = .init(role: .controller),
    exporter: DiagnosticsExporter = .init()
  ) {
    self.link = link
    self.diagnostics = diagnostics
    self.exporter = exporter
    protection = .init(session: UUID().uuidString, at: MonotonicClock().now())
    preferencesStore = try? PreferencesStore()
    preferences = preferencesStore?.load() ?? .init()
    recorder = .init()
  }

  // MARK: - Lifecycle

  func start() {
    diagnostics.started()
    // Preferences record what the user asked for; the registration itself lives in the system
    // and can be revoked there without this app hearing about it. Trusting the file would show
    // a checked menu item for a login item that does not exist, so the system is the authority.
    let registered = SMAppService.mainApp.status == .enabled
    if preferences.launchAtLogin != registered {
      mutatePreferences { $0.launchAtLogin = registered }
    }
    let validation = (try? BackendValidationStore())?.current(
      symbolName: PrivateDisplayAPI().symbolName
    )
    let observer = LivePlatformObserver(validation: validation)
    let reading = observer.read()
    if let loginID = reading.loginID {
      writerLock = try? SessionWriterLock(loginID: loginID)
    }
    lockUnavailable = writerLock == nil
    diagnostics.emit(lockUnavailable ? .writerLockUnavailable : .writerLockAcquired)
    note(
      "login=\(reading.loginID.map(String.init) ?? "nil") lock=\(writerLock != nil) validation=\(validation != nil)"
    )

    // Manual stopped being an arrangement anyone can pick. A preferences file from an older
    // build decodes into the paused arrangement, which is what manual behaved like at rest.
    let stored = preferences.mode == .manual ? .automaticPaused : preferences.mode
    var state = ControllerState(mode: stored)
    // Automatic mode resumes from preferences, but a paused choice stays paused across restarts.
    if let store = preferencesStore, let journal = try? ProductionJournalStore() {
      recorder = .init(initial: state)
      let coordinator = ProductionCoordinator(
        state: state, clock: MonotonicClock(), observer: observer, writer: LiveDisplayWriter(),
        ownership: journal, preferences: store, protection: self, delegate: self,
        session: protection.session, diagnostics: diagnostics
      )
      self.coordinator = coordinator
      coordinator.start()
    } else {
      state.fault = .journalFailed
      diagnostics.emit(.startupFailed, reason: .journalUnavailable)
      recorder = .init(initial: state)
    }
    apply(protection.receive(.start, at: MonotonicClock().now()))
    startObservingPlatform()
    // An arm reply is waited on by a disable in progress, so read it as soon as it arrives. The
    // timer below still polls, which keeps heartbeats and a missed notification covered.
    link.setReceiveHandler { [weak self] in
      Task { @MainActor in self?.receiveProtectionMessages() }
    }
    // Common mode matters: menu tracking runs a modal loop that stops default-mode timers,
    // and a controller that stops heartbeating while its menu is open looks dead to the helper.
    let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pumpProtection() }
    }
    RunLoop.main.add(timer, forMode: .common)
    protectionTimer = timer
    refreshMenu()
  }

  /// Quit asks for restoration first and only lets the app exit once nothing is unresolved.
  /// If this process dies anyway, the helper still holds recovery responsibility.
  func beginQuit() -> Bool {
    diagnostics.emit(
      .exitRequested, session: protection.session,
      reason: helperLost ? .helperLost : .userQuit
    ) {
      $0.panelOwned = coordinator?.state.ownership != nil
      $0.pendingRecovery = coordinator?.presentation.pendingRecovery
    }
    guard let coordinator else { return true }
    exiting = true
    coordinator.send(.quit)
    return coordinator.state.ownership == nil && !coordinator.state.pendingClear
  }

  func stop() {
    protectionTimer?.invalidate()
    protectionTimer = nil
    coordinator?.stop()
    for (center, token) in subscriptions {
      center.removeObserver(token)
    }
    subscriptions.removeAll()
    monitor = nil
    apply(protection.receive(.shutdown, at: MonotonicClock().now()))
    link.stop()
    writerLock?.release()
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
          self.diagnostics.emit(
            .suspended, session: self.protection.session, reason: .workspaceSleep
          )
          // Protection timing must stop too, or sleep looks like a peer that went silent.
          self.apply(self.protection.receive(.suspended, at: MonotonicClock().now()))
          coordinator.send(.willSleep)
        case NSWorkspace.didWakeNotification:
          self.diagnostics.emit(.resumed, session: self.protection.session, reason: .workspaceWake)
          self.apply(self.protection.receive(.resumed, at: MonotonicClock().now()))
          coordinator.send(.waking)
        case NSWorkspace.screensDidWakeNotification:
          self.diagnostics.emit(.resumed, session: self.protection.session, reason: .workspaceWake)
          self.apply(self.protection.receive(.resumed, at: MonotonicClock().now()))
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

  private func pumpProtection() {
    receiveProtectionMessages()
    apply(protection.receive(.tick, at: MonotonicClock().now()))
    drainDisplayEvents()
  }

  private func receiveProtectionMessages() {
    let now = MonotonicClock().now()
    do {
      while let message = try link.poll() {
        apply(protection.receive(.received(message), at: now))
      }
    } catch {
      apply(protection.receive(.peerFailed(.disconnected), at: now))
    }
  }

  private func drainDisplayEvents() {
    guard let batch = monitor?.drain(), !batch.events.isEmpty || batch.dropped > 0 else { return }
    // A lost report could have been the one that finished a reconfiguration, so assume it did not.
    let inProgress = batch.dropped > 0 || batch.events.last?.beginsConfiguration == true
    coordinator?.send(.displayReconfigured(inProgress: inProgress))
    coordinator?.platformDidChange()
  }

  // MARK: - Protection

  private var paired = false

  private func apply(_ outputs: [ControllerProtection.Output]) {
    authorization.update(protection)
    if protection.activityResumeCount != activityResumeCount {
      activityResumeCount = protection.activityResumeCount
      diagnostics.emit(.resumed, session: protection.session, reason: .activityFallback)
    }
    for output in outputs {
      switch output {
      case let .send(message): try? link.send(message)
      case .protectionEstablished:
        diagnostics.emit(.protectionReady, session: protection.session)
        if let id = pendingArm {
          pendingArm = nil
          coordinator?.send(.protectionArmed(operationID: id, succeeded: true))
        }
      case .protectionLost:
        diagnostics.emit(
          .protectionLost, session: protection.session,
          operation: protection.progress
        ) {
          $0.controllerLoss = protection.lossReason
          $0.rejection = protection.rejection
          if protection.diagnosticChallenge != nil {
            $0.challengeAgeMS = max(0, MonotonicClock().now() - protection.lastChallengeAt)
          }
          $0.challenge = protection.diagnosticChallenge
          $0.leaseDeadlineMS = protection.diagnosticLeaseDeadline
        }
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
      if pairedNow {
        diagnostics.emit(.paired, session: protection.session)
      }
      note(
        "protection phase=\(protection.phase) paired=\(pairedNow) lockUnavailable=\(lockUnavailable)"
      )
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

  func noteOperation(_ progress: OperationProgress?) {
    protection.note(progress: progress)
  }

  // MARK: - Coordinator delegate

  func coordinator(_: ProductionCoordinator, didUpdate presentation: Presentation) {
    // A full off and on round trip has just completed on this Mac and this macOS build. That is
    // exactly what a backend validation records, and it is the only thing that may write one:
    // a resolved symbol proves nothing, and neither does a suppression that was never undone.
    if previous?.panelOwned == true, !presentation.panelOwned, !presentation.pendingRecovery,
       presentation.fault == nil {
      recordBackendValidation()
    }
    if previous != presentation {
      diagnostics.emit(.stateChanged, session: protection.session) {
        $0.fault = presentation.fault
        $0.mode = presentation.mode
        $0.unavailability = presentation.unavailability
        $0.panelOwned = presentation.panelOwned
        $0.pendingRecovery = presentation.pendingRecovery
      }
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

  func coordinator(_: ProductionCoordinator, didRecord event: RecordedEvent) {
    switch event.event {
    case .observed, .tick, .displayReconfigured: break
    default: note("event \(event.event)")
    }
    _ = try? recorder.append(event)
  }

  func coordinatorIsReadyToExit(_: ProductionCoordinator) {
    guard exiting else { return }
    exiting = false
    NSApp.reply(toApplicationShouldTerminate: true)
  }

  // MARK: - Menu

  /// Evidence, not a gate. Nothing refuses to run because this is missing; it is written so a
  /// diagnostics report can say the round trip was made here, and so an OS update shows up as a
  /// record that no longer covers this system.
  private func recordBackendValidation() {
    let api = PrivateDisplayAPI()
    guard let symbol = api.symbolName, let store = try? BackendValidationStore() else { return }
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let model = BackendValidation.hardwareModel()
    guard store.current(symbolName: symbol)?
      .covers(osVersion: osVersion, hardwareModel: model, symbolName: symbol) != true
    else { return }
    try? store.save(.init(
      osVersion: osVersion, hardwareModel: model, symbolName: symbol,
      evidence: "Turned the internal panel off and saw it verified back on during normal use."
    ))
  }

  var presentation: Presentation {
    coordinator?.presentation
      ?? .init(
        mode: preferences.mode, manualRequestActive: false, panelOwned: false,
        operationInFlight: false, pendingRecovery: false, fault: .journalFailed,
        unavailability: .faulted
      )
  }

  private func refreshMenu() {
    var current = presentation
    if lockUnavailable, current.unavailability == nil {
      current.unavailability = .noRecoveryHelper
    }
    let next = MenuModel.panel(current, launchAtLogin: preferences.launchAtLogin)
    // Redrawing an identical panel would move things under the pointer for no reason.
    guard next != panel else { return }
    panel = next
    onMenuChanged?()
  }

  func perform(_ action: MenuAction) {
    let coordinator = coordinator
    diagnostics.emit(.action, session: protection.session) {
      $0.action = OperationalEvent.Action(rawValue: action.rawValue)
    }
    note("action \(action.rawValue)")
    defer { note("after \(action.rawValue): \(presentation)") }
    switch action {
    // The two tiles are stored intents, and both transitions already existed. All Monitors is
    // the paused arrangement, External Only is off whenever a monitor is there to be off for.
    case .selectAllMonitors: coordinator?.send(.keepOn)
    case .selectExternalOnly: coordinator?.send(.selectMode(.automatic))
    case .retryRecovery: coordinator?.send(.retry)
    case .toggleLaunchAtLogin: toggleLaunchAtLogin()
    case .openDisplayMonitor: onOpenDiagnostics?()
    case .exportDiagnostics: exportDiagnostics()
    case .quit: NSApp.terminate(nil)
    }
    // The coordinator persists the mode through its own effect. Re-read rather than write a
    // cached copy back, so nothing here can clobber another field.
    preferences = preferencesStore?.load() ?? preferences
    refreshMenu()
  }

  /// Additional development tracing only. Persistent operational logging uses typed fields;
  /// this raw debug stream is never included in user-facing exports.
  private func note(_ message: String) {
    #if DEBUG
      FileHandle.standardError.write(Data("SoloDisplay controller: \(message)\n".utf8))
    #endif
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

  /// Sanitized, bounded, local. Nothing is uploaded and no raw lab log is offered as an export.
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
        let trace = self.recorder.trace
        // Swift 6 requires explicit self after weak-self promotion in this isolated closure.
        // swiftformat:disable redundantSelf
        Task { @MainActor [weak self] in
          let result = await Task.detached {
            do {
              let data = try exporter.collect(trace: trace)
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
                "The current replay trace was saved, but no previous-process history was available. "
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
    // Do not enter a synchronous modal loop from a main-actor task. Recovery must keep running.
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
