#if DEBUG
  import Foundation
  import LidlessCore
  import LidlessPlatform

  /// The first mirror experiment covers exactly an external source and internal follower.
  /// Logical geometry is captured, not refresh rate, HDR, scaling preferences, or physical visibility.
  struct NativeMirrorBaseline {
    let target: PanelTarget
    let displays: [DisplayReading]

    init(_ reading: PlatformReading, external: UInt32) throws {
      guard reading.enumerationError == nil, reading.lid == .open,
        reading.foregroundSession == .yes, let target = reading.internalTarget,
        reading.displays.count == 2,
        let source = reading.displays.first(where: { $0.id == external && !$0.builtIn }),
        let follower = reading.displays.first(where: { $0.id == target.displayID }),
        source.active, source.online, !source.asleep, source.mirrored,
        source.mirrorSourceID == nil, source.uuid != nil, source.uuidResolvedID == source.id,
        follower.online, !follower.asleep, follower.mirrored,
        follower.mirrorSourceID == external, follower.uuidResolvedID == follower.id,
        reading.displays.allSatisfy({ $0.modeAvailable && $0.width > 0 && $0.height > 0 })
      else {
        throw NativeLabError.refused(
          "Expected one external mirror source and its internal follower.")
      }
      self.target = target
      displays = reading.displays.sorted { $0.id < $1.id }
    }

    func matches(_ reading: PlatformReading) -> Bool {
      reading.enumerationError == nil && reading.bootID == target.bootID
        && reading.loginID == target.loginID && reading.lid == .open
        && reading.foregroundSession == .yes
        && reading.displays.sorted { $0.id < $1.id } == displays
    }

    func externalUsable(_ reading: PlatformReading, external: UInt32) -> Bool {
      guard reading.enumerationError == nil,
        let expected = displays.first(where: { $0.id == external }),
        let actual = reading.displays.first(where: { $0.id == external })
      else { return false }
      return !actual.builtIn && actual.uuid == expected.uuid && actual.active
        && actual.online && !actual.asleep && actual.modeAvailable
        && actual.width > 0 && actual.height > 0
    }
  }

  extension NativeRecoveryLab {
    func verifyMirror(_ baseline: NativeMirrorBaseline) async throws {
      let deadline = ProcessInfo.processInfo.systemUptime + 3
      repeat {
        try await Task.sleep(for: .milliseconds(100))
        let current = DisplayObserver.read()
        try RecoveryIdentity.checkCurrentDisplays(current.displays, target: baseline.target)
        if baseline.matches(current) { return }
      } while ProcessInfo.processInfo.systemUptime < deadline
      throw NativeLabError.refused(
        "Original mirror relationship and observed layout were not restored. No topology rewrite attempted."
      )
    }
  }
#endif
