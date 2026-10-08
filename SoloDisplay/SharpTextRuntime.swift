import AppKit
import CoreGraphics
import SoloDisplayCore
import SoloDisplayPlatform

/// Keeps text sharp on monitors macOS leaves blurry. Below native resolution it moves a monitor
/// to the hidden 2x mode at the same size and refresh rate, the way macOS already treats 4K
/// panels. Nothing on screen changes size; only the rendering does.
///
/// This process only decides from public readings that a monitor is worth a look. The worker
/// reads the private mode list, decides again, switches, and reads the result back.
@MainActor
final class SharpTextRuntime {
  /// Called when what the menu says may have changed.
  var onChange: (() -> Void)?
  /// False while another display change is under way, so two never race.
  var canAct: () -> Bool = { true }
  /// Connected monitors, and how many of them Sharp Text cannot help, for the menu.
  private(set) var monitors = 0
  private(set) var unavailable = 0
  /// A lit monitor is rendering at 2x, whoever put it there. macOS does it on its own for 4K.
  private(set) var externalSharp = false

  private let writer: WorkerDisplayWriter?
  private var enabled = false
  private var busy = false
  private var timer: Timer?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  /// The last mode tried per monitor UUID and how it went. A mode that did not work is not tried
  /// again, so a monitor that cannot do it is not asked on every notification. A new mode starts
  /// over.
  private var attempts: [String: Attempt] = [:]

  private struct Attempt {
    var size: ModeSize
    var refreshRate: Int
    var outcome: Outcome
  }

  private enum Outcome { case trying, sharp, unavailable, failed }

  /// Resolution changes, plugging in and waking all arrive as bursts.
  private static let settleSeconds = 1.5

  init() {
    writer = Bundle.main.executableURL.map { WorkerDisplayWriter(executable: $0) }
    let changes: [(NotificationCenter, Notification.Name)] = [
      (.default, NSApplication.didChangeScreenParametersNotification),
      (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
      (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification)
    ]
    for (center, name) in changes {
      let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.schedule() }
      }
      observers.append((center, token))
    }
    schedule(after: 0)
  }

  /// Turning it off puts back the plain mode once, right then. After that Sharp Text leaves the
  /// displays alone, even a hidden 2x mode some other tool sets.
  func setEnabled(_ value: Bool) {
    guard value != enabled else { return }
    enabled = value
    attempts.removeAll()
    if value {
      schedule(after: 0)
    } else {
      Task { await restore() }
    }
    refresh()
  }

  func stop() {
    timer?.invalidate()
    for (center, token) in observers {
      center.removeObserver(token)
    }
    observers.removeAll()
  }

  // MARK: - Deciding

  /// Runs whether or not the option is on, because the artwork shows sharp monitors either way.
  private func schedule(after delay: Double = settleSeconds) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.evaluate() }
    }
  }

  private func evaluate() {
    let reading = DisplayObserver.read()
    let displays = reading.displays.filter { !$0.builtIn && $0.online }
    let lit = displays.filter { $0.active && !$0.asleep && !$0.mirrored }
    monitors = displays.count
    externalSharp = lit.contains { DisplayModeCatalog.current($0.id)?.scale == 2 }
    // A monitor that has gone is forgotten. Plugged back in, it starts fresh.
    let present = Set(displays.compactMap(\.uuid))
    attempts = attempts.filter { present.contains($0.key) }
    defer { refresh() }
    guard enabled, !busy else { return }
    guard canAct() else {
      schedule()
      return
    }
    for display in lit {
      guard let target = target(display, reading),
            let current = DisplayModeCatalog.current(display.id)
      else { continue }
      let publicModes = DisplayModeCatalog.publicModes(display.id)
      let native = SharpText.native(
        flagged: DisplayModeCatalog.nativeSizes(publicModes),
        catalog: publicModes.map(DisplayModeCatalog.summary)
      )
      guard SharpText.candidate(current, native: native),
            // macOS lists a 2x mode of this size itself, so plain was the person's choice.
            SharpText.twin(
              of: current.size, refreshRate: current.refreshRate,
              in: publicModes.map(DisplayModeCatalog.summary)
            ) == nil
      else { continue }
      // Plain again after being sharp means someone chose this mode anew, so it is tried again.
      if let last = attempts[target.displayUUID], last.outcome != .sharp,
         last.size == current.size, last.refreshRate == current.refreshRate {
        continue
      }
      let attempt = Attempt(
        size: current.size, refreshRate: current.refreshRate, outcome: .trying
      )
      attempts[target.displayUUID] = attempt
      // One at a time. The next monitor is looked at once this one is done.
      Task { await sharpen(target, attempt) }
      return
    }
  }

  private func target(_ display: DisplayReading, _ reading: PlatformReading) -> PanelTarget? {
    guard let uuid = display.uuid, let bootID = reading.bootID, let loginID = reading.loginID
    else { return nil }
    return .init(
      displayID: display.id, displayUUID: uuid, bootID: bootID, loginID: loginID,
      kind: .external
    )
  }

  // MARK: - Switching

  private func sharpen(_ target: PanelTarget, _ attempt: Attempt) async {
    var record = attempt
    let request = DisplayWorkerRequest.ModeRequest(
      width: attempt.size.width, height: attempt.size.height,
      refreshRate: attempt.refreshRate, scale: 2
    )
    switch await run(request, target) {
    case .done: record.outcome = .sharp
    case .unavailable: record.outcome = .unavailable
    case .refused, .failed: record.outcome = .failed
    }
    // Turned off while the worker ran: whatever it did is undone.
    guard enabled else {
      await restore()
      return
    }
    attempts[target.displayUUID] = record
    schedule()
  }

  /// One worker at a time, so two mode changes never overlap. The worker blocks, so
  /// it is
  /// waited for off the main thread.
  private func run(
    _ request: DisplayWorkerRequest.ModeRequest, _ target: PanelTarget
  ) async -> ModeOutcome {
    guard let writer else { return .failed }
    while busy {
      try? await Task.sleep(for: .milliseconds(100))
    }
    busy = true
    defer { busy = false }
    return await Task.detached { writer.setMode(request, target: target) }.value
  }

  /// Puts the plain mode back on every lit monitor in a hidden 2x mode. The mode itself says it
  /// is Sharp Text's kind of switch, so this works after a restart too, with nothing remembered.
  private func restore() async {
    let reading = DisplayObserver.read()
    for display in reading.displays where !display.builtIn && display.active && !display.mirrored {
      guard !enabled, let mode = CGDisplayCopyDisplayMode(display.id),
            DisplayModeCatalog.isHiddenSharp(mode), let target = target(display, reading)
      else { continue }
      let current = DisplayModeCatalog.summary(mode)
      _ = await run(
        .init(
          width: current.width, height: current.height, refreshRate: current.refreshRate,
          scale: 1
        ),
        target
      )
    }
  }

  private func refresh() {
    unavailable = enabled ? attempts.values.count(where: { $0.outcome == .unavailable }) : 0
    onChange?()
  }
}
