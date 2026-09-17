import AppKit
import ApplicationServices
import CoreGraphics
import os
import SoloDisplayPlatform

/// Sends the brightness keys to the external monitor while SoloDisplay has the laptop screen
/// off. At any other time, or when no monitor answers over DDC, the keys pass through to macOS.
///
/// The event tap needs Accessibility permission. Monitor calls run on each display's own queue,
/// so a monitor that stops answering never holds up the keyboard.
@MainActor
final class BrightnessKeys {
  /// Called when `needsPermission` changes.
  var onChange: (() -> Void)?
  private(set) var needsPermission = false

  private var enabled = false
  private var active = false
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var permissionTimer: Timer?
  private var screenObserver: NSObjectProtocol?

  /// Display ID to controller, for externals that can be told apart for certain.
  private var controllers: [CGDirectDisplayID: String]?
  private var lanes: [String: BrightnessLane] = [:]
  private var levels: [String: BrightnessLevel] = [:]
  private var lastPress: [String: Date] = [:]
  private var waiting: [String: [BrightnessKey]] = [:]
  /// Monitors that did not answer, and when. They are tried again after a while, since a
  /// monitor that was just connected may not answer yet.
  private var unanswered: [String: Date] = [:]

  /// A level older than this is read again, in case the monitor's own buttons changed it.
  private let log = Logger(subsystem: UnifiedOperationalSink.subsystem, category: "brightness")
  private static let levelLifetime: TimeInterval = 5
  private static let unansweredLifetime: TimeInterval = 10

  init() {
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.forgetDisplays() }
    }
  }

  /// Asking for permission is only done when the person turns the setting on.
  func setEnabled(_ value: Bool, askForPermission: Bool) {
    enabled = value
    if value, askForPermission {
      // The value of kAXTrustedCheckOptionPrompt, which Swift 6 will not read as a global.
      _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    reconcile()
  }

  /// True while SoloDisplay has the laptop screen off.
  func setActive(_ value: Bool) {
    guard value != active else { return }
    active = value
    // A new stretch with the screen off starts from what the monitor says.
    levels.removeAll()
    reconcile()
  }

  func stop() {
    enabled = false
    reconcile()
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
    }
  }

  // MARK: - Tap and permission

  private func reconcile() {
    let trusted = AXIsProcessTrusted()
    setNeedsPermission(enabled && !trusted)
    if enabled, !trusted {
      startPermissionPolling()
    } else {
      stopPermissionPolling()
    }
    if enabled, active, trusted {
      installTap()
    } else {
      removeTap()
    }
  }

  private func setNeedsPermission(_ value: Bool) {
    guard value != needsPermission else { return }
    needsPermission = value
    onChange?()
  }

  /// macOS does not announce a permission change, so it is checked while it is missing.
  private func startPermissionPolling() {
    guard permissionTimer == nil else { return }
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.reconcile() }
    }
    RunLoop.main.add(timer, forMode: .common)
    permissionTimer = timer
  }

  private func stopPermissionPolling() {
    permissionTimer?.invalidate()
    permissionTimer = nil
  }

  private func installTap() {
    guard tap == nil else { return }
    let systemDefined = CGEventMask(1) << 14 // NX_SYSDEFINED
    let mask = systemDefined
      | CGEventMask(1) << CGEventType.keyDown.rawValue
      | CGEventMask(1) << CGEventType.keyUp.rawValue
    guard let port = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: mask, callback: brightnessTapCallback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      log.error("event tap could not be created")
      return
    }
    let source = CFMachPortCreateRunLoopSource(nil, port, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    tap = port
    self.source = source
  }

  private func removeTap() {
    guard let tap else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    if let source {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    CFMachPortInvalidate(tap)
    self.tap = nil
    source = nil
  }

  /// True when the event was used and must not reach macOS.
  fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      log.error("event tap disabled by the system, type \(type.rawValue, privacy: .public)")
      if let tap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      return false
    case .keyDown, .keyUp:
      let code = event.getIntegerValueField(.keyboardEventKeycode)
      guard let key = BrightnessKey.from(keyCode: code) else { return false }
      return route(key, pressed: type == .keyDown)
    default:
      guard type.rawValue == 14, let decoded = NSEvent(cgEvent: event),
            let key = BrightnessKey.decode(
              subtype: decoded.subtype.rawValue, data1: decoded.data1
            )
      else { return false }
      return route(key.key, pressed: key.pressed)
    }
  }

  // MARK: - Brightness

  private func route(_ key: BrightnessKey, pressed: Bool) -> Bool {
    guard active, let (displayID, controller) = target() else { return false }
    if pressed {
      press(key, controller: controller, displayID: displayID)
    }
    return true
  }

  /// The monitor under the pointer, else the main display, else any monitor that answers.
  private func target() -> (CGDirectDisplayID, String)? {
    let now = Date()
    unanswered = unanswered.filter { now.timeIntervalSince($0.value) < Self.unansweredLifetime }
    let known = currentControllers().filter { unanswered[$0.value] == nil }
    guard !known.isEmpty else { return nil }
    var pointer = [CGDirectDisplayID](repeating: 0, count: 1)
    var count: UInt32 = 0
    let location = CGEvent(source: nil)?.location ?? .zero
    CGGetDisplaysWithPoint(location, 1, &pointer, &count)
    for candidate in [count > 0 ? pointer[0] : 0, CGMainDisplayID()] {
      if let controller = known[candidate] {
        return (candidate, controller)
      }
    }
    return known.min { $0.key < $1.key }.map { ($0.key, $0.value) }
  }

  private func currentControllers() -> [CGDirectDisplayID: String] {
    if let controllers {
      return controllers
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
    // Apple displays take the brightness keys from macOS already.
    let externals = ids.prefix(Int(count)).filter {
      CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != Self.appleVendor
    }
    let services = Set(IOAVServiceDDC.externalControllers())
    let found = IOAVServiceDDC.controllers(forDisplays: Array(externals))
      .filter { services.contains($0.value) }
    controllers = found
    return found
  }

  private static let appleVendor: UInt32 = 0x0610

  /// A connected or disconnected monitor can change display IDs and DDC services, so
  /// everything learned about the old ones is dropped, including their open connections.
  private func forgetDisplays() {
    controllers = nil
    unanswered.removeAll()
    levels.removeAll()
    lastPress.removeAll()
    waiting.removeAll()
    lanes.removeAll()
  }

  private func press(_ key: BrightnessKey, controller: String, displayID: CGDirectDisplayID) {
    let now = Date()
    let fresh = lastPress[controller].map { now.timeIntervalSince($0) < Self.levelLifetime }
    lastPress[controller] = now
    if let level = levels[controller], fresh == true {
      apply(key, to: level, controller: controller, displayID: displayID)
      return
    }
    let pending = waiting[controller] != nil
    waiting[controller, default: []].append(key)
    guard !pending else { return }
    lane(controller).read { [weak self] level in
      Task { @MainActor in
        self?.didRead(level, controller: controller, displayID: displayID)
      }
    }
  }

  private func didRead(_ level: BrightnessLevel?, controller: String,
                       displayID: CGDirectDisplayID) {
    let keys = waiting.removeValue(forKey: controller) ?? []
    guard var level else {
      // This monitor does not answer. Its keys go back to macOS for a while.
      unanswered[controller] = Date()
      return
    }
    levels[controller] = level
    for key in keys {
      level = apply(key, to: level, controller: controller, displayID: displayID)
    }
  }

  @discardableResult
  private func apply(_ key: BrightnessKey, to level: BrightnessLevel, controller: String,
                     displayID: CGDirectDisplayID) -> BrightnessLevel {
    let next = level.stepped(key)
    levels[controller] = next
    if next != level {
      lane(controller).write(next.value)
    }
    BrightnessIndicator.show(
      filled: next.filledSteps, of: BrightnessLevel.steps, on: displayID
    )
    return next
  }

  private func lane(_ controller: String) -> BrightnessLane {
    if let existing = lanes[controller] {
      return existing
    }
    let lane = BrightnessLane(controller: controller)
    lanes[controller] = lane
    return lane
  }
}

/// The tap runs on the main run loop, so its callback is on the main thread.
private nonisolated func brightnessTapCallback(
  _: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let info else { return Unmanaged.passUnretained(event) }
  let keys = Unmanaged<BrightnessKeys>.fromOpaque(info).takeUnretainedValue()
  // The event stays on this thread; it is only read here and returned below.
  nonisolated(unsafe) let unsent = event
  let used = MainActor.assumeIsolated { keys.handle(type, unsent) }
  return used ? nil : Unmanaged.passUnretained(event)
}
