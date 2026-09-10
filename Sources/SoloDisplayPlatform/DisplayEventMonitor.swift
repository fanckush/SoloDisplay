import CoreGraphics
import Foundation

public struct DisplayChangeEvent: Codable, Sendable {
  public var at: Int64
  public var displayID: UInt32
  public var flags: UInt32
  public var beginsConfiguration: Bool
}

/// The callback only records evidence. It never observes or reconfigures displays recursively.
public final class DisplayEventMonitor {
  private final class Storage {
    let lock = NSLock()
    var events: [DisplayChangeEvent] = []
    var dropped = 0
    func append(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
      let event = DisplayChangeEvent(
        at: Int64(ProcessInfo.processInfo.systemUptime * 1000),
        displayID: display, flags: flags.rawValue,
        beginsConfiguration: flags.contains(.beginConfigurationFlag)
      )
      lock.withLock {
        if events.count < 1024 {
          events.append(event)
        } else {
          dropped += 1
        }
      }
    }
  }

  private let storage = Storage()
  public let registrationError: Int32?
  private static let callback: CGDisplayReconfigurationCallBack = { display, flags, context in
    guard let context else { return }
    Unmanaged<Storage>.fromOpaque(context).takeUnretainedValue().append(
      display: display, flags: flags
    )
  }

  public init() {
    let result = CGDisplayRegisterReconfigurationCallback(
      Self.callback, Unmanaged.passUnretained(storage).toOpaque()
    )
    registrationError = result == .success ? nil : result.rawValue
  }

  deinit {
    if registrationError == nil {
      CGDisplayRemoveReconfigurationCallback(
        Self.callback, Unmanaged.passUnretained(storage).toOpaque()
      )
    }
  }

  public func drain() -> (events: [DisplayChangeEvent], dropped: Int) {
    storage.lock.withLock {
      let result = (storage.events, storage.dropped)
      storage.events.removeAll(keepingCapacity: true)
      storage.dropped = 0
      return result
    }
  }
}
