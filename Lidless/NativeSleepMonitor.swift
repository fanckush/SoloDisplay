#if DEBUG
  import AppKit
  import Synchronization

  /// The system notifications are separate from screen sleep and from display activity.
  /// Capture synchronously into a lock so independently queued Tasks cannot reorder them.
  nonisolated struct NativeSleepCycle: Sendable, Equatable {
    enum Event: Sendable { case willSleep, didWake }
    private(set) var sleeping = false
    private(set) var sleepCount = 0
    private(set) var wakeCount = 0

    mutating func receive(_ event: Event) {
      switch event {
      case .willSleep:
        if !sleeping {
          sleepCount += 1
        }
        sleeping = true
      case .didWake:
        if sleeping {
          wakeCount += 1
        }
        sleeping = false
      }
    }

    var completed: Bool {
      sleepCount > 0 && wakeCount > 0 && !sleeping
    }
  }

  @MainActor
  final class NativeSleepMonitor {
    private final nonisolated class Storage: Sendable {
      let value = Mutex(NativeSleepCycle())
    }

    private let state = Storage()
    private var subscriptions: [NSObjectProtocol] = []
    private let center = NSWorkspace.shared.notificationCenter

    init() {
      let state = state
      subscriptions.append(
        center.addObserver(
          forName: NSWorkspace.willSleepNotification,
          object: nil, queue: nil
        ) { _ in state.value.withLock { $0.receive(.willSleep) } }
      )
      subscriptions.append(
        center.addObserver(
          forName: NSWorkspace.didWakeNotification,
          object: nil, queue: nil
        ) { _ in state.value.withLock { $0.receive(.didWake) } }
      )
    }

    var snapshot: NativeSleepCycle {
      state.value.withLock { $0 }
    }

    func stop() {
      for token in subscriptions {
        center.removeObserver(token)
      }
      subscriptions.removeAll()
    }

    /// No visibility demand or display write while a recorded system sleep is outstanding.
    /// This deliberately waits for wake rather than claiming a wall-clock recovery guarantee
    /// while macOS can suspend both processes. No sleep-prevention assertion is held.
    func awaitWakeIfSleeping() async throws {
      while snapshot.sleeping {
        try await Task.sleep(for: .milliseconds(100))
      }
    }
  }
#endif
