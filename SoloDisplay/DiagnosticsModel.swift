import AppKit
import Observation
import enum SoloDisplayCore.Fact
import enum SoloDisplayCore.Lid
import enum SoloDisplayCore.Power
import struct SoloDisplayCore.ShadowController
import SoloDisplayPlatform

struct DiagnosticEntry: Identifiable {
  let id: UInt64
  let milliseconds: Int64
  let reason: String
  let detail: String
}

struct DiagnosticHistory {
  private(set) var entries: [DiagnosticEntry] = []
  private(set) var discarded = 0
  private var nextID: UInt64 = 0
  let capacity: Int

  init(capacity: Int = 128) {
    self.capacity = max(1, capacity)
  }

  mutating func append(milliseconds: Int64, reason: String, detail: String) {
    nextID += 1
    entries.append(.init(id: nextID, milliseconds: milliseconds, reason: reason, detail: detail))
    if entries.count > capacity {
      let overflow = entries.count - capacity
      entries.removeFirst(overflow)
      discarded += overflow
    }
  }
}

enum DiagnosticPresentation {
  static func headline(inventoryAvailable: Bool, mirrored: Bool) -> String {
    if !inventoryAvailable {
      return "Display inventory unavailable"
    }
    if mirrored {
      return "Mirroring detected"
    }
    return "Display inventory available"
  }

  static func activity(active: Bool, asleep: Bool) -> String {
    if asleep {
      return "Reported asleep"
    }
    return active ? "Reported active" : "Not active (not proof of off)"
  }
}

/// Development instrumentation only. There is deliberately no display writer here.
@MainActor @Observable
final class DiagnosticsModel {
  private(set) var reading: PlatformReading?
  private(set) var history = DiagnosticHistory()
  private(set) var callbackRegistrationError: Int32?
  private(set) var droppedCallbacks = 0
  private(set) var controller = ShadowController()
  private(set) var powerEvidence: Power = .unknown
  /// Counted rather than inferred from the newest entry, which a periodic sample can replace.
  private(set) var manualRefreshes = 0
  @ObservationIgnored private var monitor: DisplayEventMonitor?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var subscriptions: [(NotificationCenter, NSObjectProtocol)] = []
  @ObservationIgnored private var lastPoll: Int64 = 0

  var headline: String {
    DiagnosticPresentation.headline(
      inventoryAvailable: reading.map { $0.enumerationError == nil && !$0.displays.isEmpty }
        ?? false,
      mirrored: reading?.mirroringDetected ?? false
    )
  }

  func start() {
    guard monitor == nil else { return }
    let monitor = DisplayEventMonitor()
    self.monitor = monitor
    callbackRegistrationError = monitor.registrationError
    subscribe(
      .default, NSApplication.didChangeScreenParametersNotification, reason: "AppKit screen change"
    )
    let workspace = NSWorkspace.shared.notificationCenter
    subscribe(workspace, NSWorkspace.willSleepNotification, reason: "System will sleep")
    subscribe(workspace, NSWorkspace.didWakeNotification, reason: "System woke")
    subscribe(workspace, NSWorkspace.screensDidSleepNotification, reason: "Screens slept")
    subscribe(workspace, NSWorkspace.screensDidWakeNotification, reason: "Screens woke")
    subscribe(
      workspace, NSWorkspace.sessionDidBecomeActiveNotification, reason: "GUI session active"
    )
    subscribe(
      workspace, NSWorkspace.sessionDidResignActiveNotification, reason: "GUI session inactive"
    )
    sample(reason: "AppKit launch")
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.poll() }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    for (center, token) in subscriptions {
      center.removeObserver(token)
    }
    subscriptions.removeAll()
    monitor = nil
  }

  func refresh() {
    manualRefreshes += 1
    sample(reason: "Manual refresh")
  }

  private func subscribe(_ center: NotificationCenter, _ name: Notification.Name, reason: String) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      // Queue evidence handling after the notification, never reenter a callback.
      Task { @MainActor [weak self] in
        guard let self, monitor != nil else { return }
        let now = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        switch name {
        case NSWorkspace.willSleepNotification:
          powerEvidence = .sleeping
          controller.receive(.willSleep, at: now)
        case NSWorkspace.didWakeNotification:
          powerEvidence = .waking
          controller.receive(.waking, at: now)
        case NSWorkspace.screensDidSleepNotification:
          powerEvidence = .unknown
          controller.receive(.keepOn, at: now)
        case NSWorkspace.sessionDidResignActiveNotification:
          controller.receive(.keepOn, at: now)
        default: break
        }
        sample(reason: reason)
      }
    }
    subscriptions.append((center, token))
  }

  private func poll() {
    guard monitor != nil else { return }
    let now = Int64(ProcessInfo.processInfo.systemUptime * 1000)
    controller.tick(at: now)
    let receivedCallbacks = drainCallbacks()
    if receivedCallbacks || now - lastPoll >= 2000 {
      sample(reason: receivedCallbacks ? "After display callback" : "Periodic observation")
    }
  }

  @discardableResult private func drainCallbacks() -> Bool {
    guard let batch = monitor?.drain() else { return false }
    droppedCallbacks += batch.dropped
    for event in batch.events {
      history.append(
        milliseconds: event.at, reason: "CoreGraphics callback",
        detail:
        "Display \(event.displayID), flags \(event.flags), begin \(event.beginsConfiguration)"
      )
    }
    return !batch.events.isEmpty || batch.dropped > 0
  }

  private func sample(reason: String) {
    drainCallbacks()
    let next = DisplayObserver.read()
    // Periodic unchanged observations update freshness without evicting useful events.
    let changed =
      reading.map {
        $0.displays != next.displays || $0.lid != next.lid
          || $0.foregroundSession != next.foregroundSession
          || $0.enumerationError != next.enumerationError
      } ?? true
    reading = next
    controller.observe(
      ControllerObservation.environment(next, power: powerEvidence), at: next.monotonicMilliseconds
    )
    lastPoll = next.monotonicMilliseconds
    if changed || reason != "Periodic observation" {
      let inventory = next.displays.map { "\($0.id): active=\($0.active), mirror=\($0.mirrored)" }
        .joined(separator: "; ")
      history.append(
        milliseconds: next.monotonicMilliseconds, reason: reason,
        detail: inventory.isEmpty
          ? "Inventory unavailable; not evidence of zero connected displays" : inventory
      )
    }
  }
}
