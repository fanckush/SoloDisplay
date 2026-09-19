import Dispatch
import Foundation
import os
import Synchronization

/// One external monitor's DDC traffic, serialized. Everything in this process that talks to a
/// monitor shares its lane: the bus is one wire, and a reply belongs to whichever request was
/// last on it. Two callers interleaving would each read the other's reply and both would fail.
/// The connection is opened once and dropped after any failure, because a reconnected monitor
/// gets a new service.
public final class DDCLane: Sendable {
  private static let log = Logger(subsystem: UnifiedOperationalSink.subsystem, category: "ddc")

  public let controller: String
  /// Shared with callers that drive their own work on this lane, so it stays one queue per
  /// monitor however many of them there are.
  let queue: DispatchQueue
  private let channel = Mutex<DDCChannel?>(nil)

  init(controller: String) {
    self.controller = controller
    queue = DispatchQueue(label: "SoloDisplay.ddc.\(controller)", qos: .userInitiated)
  }

  /// Runs one exchange and waits for it. Never from the main thread, and never from this lane.
  public func perform<T: Sendable>(_ body: @Sendable (DDCChannel) throws -> T) -> T? {
    queue.sync { performOnLane(body) }
  }

  /// Runs one exchange on the lane and completes there, with nil when the monitor did not answer.
  public func run<T: Sendable>(
    _ body: @escaping @Sendable (DDCChannel) throws -> T,
    completion: @escaping @Sendable (T?) -> Void
  ) {
    queue.async { [self] in completion(performOnLane(body)) }
  }

  /// For a caller already running on this lane. Opening is retried on the next call.
  func performOnLane<T: Sendable>(_ body: (DDCChannel) throws -> T) -> T? {
    do {
      return try body(open())
    } catch {
      let name = controller
      let reason = String(describing: error)
      Self.log.error("\(name, privacy: .public): \(reason, privacy: .public)")
      channel.withLock { $0 = nil }
      return nil
    }
  }

  private func open() throws -> DDCChannel {
    if let existing = channel.withLock({ $0 }) {
      return existing
    }
    let opened = try IOAVServiceDDC.channel(controller: controller)
    channel.withLock { $0 = opened }
    return opened
  }
}

/// The one lane per monitor in this process.
public enum DDCLanes {
  private static let lanes = Mutex<[String: DDCLane]>([:])

  public static func lane(for controller: String) -> DDCLane {
    lanes.withLock { lanes in
      if let existing = lanes[controller] {
        return existing
      }
      let lane = DDCLane(controller: controller)
      lanes[controller] = lane
      return lane
    }
  }

  /// A connected or disconnected monitor changes services, so the lanes go with them.
  public static func forget() {
    lanes.withLock { $0.removeAll() }
  }
}
