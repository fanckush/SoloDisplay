import CoreGraphics
import Foundation
import SoloDisplayCore

/// Monotonic uptime. A wall clock would let a time change reorder the controller's history.
public struct MonotonicClock: CoordinatorClock {
  public init() {}
  public func now() -> Instant {
    Int64(ProcessInfo.processInfo.systemUptime * 1000)
  }
}

/// Read-only platform observation.
public struct LivePlatformObserver: PlatformObserving {
  public init() {}

  public func read() -> PlatformReading {
    DisplayObserver.read()
  }
}

extension ProductionJournalStore: OwnershipPersisting {}

extension PreferencesStore: PreferencePersisting {
  public func save(mode: Mode) throws {
    try update { $0.mode = mode }
  }
}

extension ExternalSuppressionStore: SuppressionPersisting {
  public func save(_ targets: [PanelTarget], session: String) throws {
    try save(.init(session: session, targets: targets))
  }

  public func suppressedTargets() -> [PanelTarget] {
    load()?.targets ?? []
  }
}
