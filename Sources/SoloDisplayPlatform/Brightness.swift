import Dispatch
import Foundation
import os
import Synchronization

public enum BrightnessKey: Equatable, Sendable {
  case up, down

  /// The `NSEvent` subtype of system-defined auxiliary control button events.
  public static let auxControlSubtype: Int16 = 8
  /// Brightness keys on keyboards that report them as ordinary key codes.
  public static let upKeyCode: Int64 = 144
  public static let downKeyCode: Int64 = 145

  /// Decodes a system-defined event's `data1`: the key type in the high 16 bits, and the key
  /// state (0x0A down, 0x0B up) in the byte above the repeat flag. Other keys give nil.
  public static func decode(subtype: Int16, data1: Int) -> (key: BrightnessKey, pressed: Bool)? {
    guard subtype == auxControlSubtype else { return nil }
    let key: BrightnessKey
    switch (data1 >> 16) & 0xFFFF {
    case 2: key = .up // NX_KEYTYPE_BRIGHTNESS_UP
    case 3: key = .down // NX_KEYTYPE_BRIGHTNESS_DOWN
    default: return nil
    }
    return (key, (data1 >> 8) & 0xFF == 0x0A)
  }

  public static func from(keyCode: Int64) -> BrightnessKey? {
    switch keyCode {
    case upKeyCode: .up
    case downKeyCode: .down
    default: nil
    }
  }
}

/// A monitor's brightness, moved in the same 16 steps as the built-in panel.
public struct BrightnessLevel: Equatable, Sendable {
  public static let steps = 16

  public var value: UInt16
  public var maximum: UInt16

  public init(value: UInt16, maximum: UInt16) {
    self.value = value
    self.maximum = maximum
  }

  public var fraction: Double {
    maximum == 0 ? 0 : min(1, Double(value) / Double(maximum))
  }

  /// How many of the 16 steps are lit, as the system indicator draws them.
  public var filledSteps: Int {
    Int((fraction * Double(Self.steps)).rounded())
  }

  /// Snaps to the nearest step first, so a value set elsewhere joins the same scale.
  public func stepped(_ key: BrightnessKey) -> BrightnessLevel {
    guard maximum > 0 else { return self }
    let step = Double(maximum) / Double(Self.steps)
    let current = Int((Double(min(value, maximum)) / step).rounded())
    let next = min(Self.steps, max(0, current + (key == .up ? 1 : -1)))
    return .init(value: UInt16((Double(next) * step).rounded()), maximum: maximum)
  }
}

/// Runs writes one at a time on a queue and keeps only the newest value that is still waiting.
/// A write that stalls never blocks the caller; values submitted meanwhile replace each other.
public final class LatestValueWriter<Value: Sendable>: Sendable {
  private struct State {
    var latest: Value?
    var running = false
  }

  private let queue: DispatchQueue
  private let state = Mutex(State())
  private let write: @Sendable (Value) -> Void

  public init(queue: DispatchQueue, write: @escaping @Sendable (Value) -> Void) {
    self.queue = queue
    self.write = write
  }

  public func submit(_ value: Value) {
    let start = state.withLock { state in
      state.latest = value
      guard !state.running else { return false }
      state.running = true
      return true
    }
    if start {
      queue.async { self.drain() }
    }
  }

  private func drain() {
    while let value = state.withLock({ state -> Value? in
      guard let value = state.latest else {
        state.running = false
        return nil
      }
      state.latest = nil
      return value
    }) {
      write(value)
    }
  }
}

/// Brightness for one external display, on that display's shared DDC lane so a display that
/// stops answering only delays itself, and so it never interleaves with other DDC traffic.
public final class BrightnessLane: Sendable {
  public let controller: String
  private let lane: DDCLane
  private let writer: LatestValueWriter<UInt16>

  public init(controller: String) {
    self.controller = controller
    let lane = DDCLanes.lane(for: controller)
    self.lane = lane
    // The writer drains on the lane itself, so the exchange is already where it belongs.
    writer = LatestValueWriter(queue: lane.queue) { value in
      lane.performOnLane { try $0.set(code: DDCPacket.brightness, value: value) }
    }
  }

  /// Completes on the lane's queue, with nil when the display does not answer.
  public func read(_ completion: @escaping @Sendable (BrightnessLevel?) -> Void) {
    lane.run { try $0.get(code: DDCPacket.brightness) } completion: { value in
      completion(value.map { BrightnessLevel(value: $0.current, maximum: $0.maximum) })
    }
  }

  public func write(_ value: UInt16) {
    writer.submit(value)
  }
}
