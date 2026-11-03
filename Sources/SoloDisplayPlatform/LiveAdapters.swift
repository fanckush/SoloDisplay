import CoreGraphics
import Foundation
import IOKit.pwr_mgt
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

/// What pressing the power button and then a key does: every display sleeps, then wakes. macOS
/// does the sleeping itself through `pmset`, and user activity wakes them.
public struct LiveDisplayRefresher: DisplayRefreshing {
  /// Long enough for a monitor to actually go dark. One second and a half was seen to work.
  private static let asleepFor = 2.0

  public init() {}

  public func refresh() {
    let sleep = Process()
    sleep.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    sleep.arguments = ["displaysleepnow"]
    sleep.standardOutput = FileHandle.nullDevice
    sleep.standardError = FileHandle.nullDevice
    guard (try? sleep.run()) != nil else { return }
    sleep.waitUntilExit()
    Thread.sleep(forTimeInterval: Self.asleepFor)
    // Left to time out on its own, the same as any other activity.
    var assertion = IOPMAssertionID(0)
    _ = IOPMAssertionDeclareUserActivity(
      "SoloDisplay redraw" as CFString, kIOPMUserActiveLocal, &assertion
    )
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
