import CoreGraphics
import Foundation
import LidlessCore

/// Monotonic uptime. A wall clock would let a time change reorder the controller's history.
public struct MonotonicClock: CoordinatorClock {
  public init() {}
  public func now() -> Instant { Int64(ProcessInfo.processInfo.systemUptime * 1_000) }
}

/// Read-only platform observation carrying whatever backend validation this run has.
public struct LivePlatformObserver: PlatformObserving {
  private let validation: BackendValidation?
  public init(validation: BackendValidation?) { self.validation = validation }
  public func read() -> PlatformReading { DisplayObserver.read(validation: validation) }
}

/// The only production path to the private call. It is always reached from the serial lane.
public struct LiveDisplayWriter: DisplayWriting {
  public init() {}
  public func setEnabled(_ enabled: Bool, displayID: UInt32, scope: DisplayScope) throws {
    try PrivateDisplayAPI().setEnabled(
      enabled, displayID: displayID, scope: scope == .application ? .forAppOnly : .forSession)
  }
}

extension ProductionJournalStore: OwnershipPersisting {}

extension PreferencesStore: PreferencePersisting {
  public func save(mode: Mode) throws { try update { $0.mode = mode } }
}
