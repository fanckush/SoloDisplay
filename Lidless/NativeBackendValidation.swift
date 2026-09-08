#if DEBUG
  import CoreGraphics
  import Foundation
  import LidlessCore
  import LidlessPlatform

  /// The guided round trip that lets production trust the private call on this Mac. It records
  /// nothing unless the panel actually went off and came back with its arrangement intact.
  /// A resolved symbol never reaches this record, and neither does a failed or partial run.
  extension NativeRecoveryLab {
    func validateBackend(external: UInt32, path: String) async throws {
      let api = PrivateDisplayAPI()
      guard let symbol = api.symbolName else { throw DisplayAPIError.unavailable }
      guard !FileManager.default.fileExists(atPath: path) else {
        throw NativeLabError.refused("A new journal path is required.")
      }
      let initial = DisplayObserver.read()
      let mirror =
        initial.mirroringDetected ? try NativeMirrorBaseline(initial, external: external) : nil
      let target = try mirror?.target ?? NativeLabSafety.baseline(initial, external: external)

      // The production controller holds this lock while it runs, so this refuses to compete.
      let lock = try SessionWriterLock(loginID: target.loginID)
      defer { lock.release() }
      let journal = RecoveryJournal(target: target, scope: "app", ownerPID: getpid())
      try journal.save(to: URL(fileURLWithPath: path))
      try report("backend-validation-baseline")
      print(
        """
        Lidless will turn the internal display off for about three seconds, then turn it back on.
        Watch the internal screen. Arrangement: \(mirror == nil ? "extended" : "mirrored").
        """)
      fflush(stdout)

      var suppressed = false
      do {
        try api.setEnabled(false, displayID: target.displayID, scope: .forAppOnly)
        suppressed = true
        try await confirmSuppressed(
          target: target, external: external, mirror: mirror,
          wasActive: initial.displays.contains { $0.id == target.displayID && $0.active })
        try report("backend-validation-suppressed")
        try await Task.sleep(for: .seconds(3))
        try NativeLabSafety.ownedContext(DisplayObserver.read(), journal: journal)
        try api.setEnabled(true, displayID: target.displayID, scope: .forAppOnly)
        suppressed = false
        if let mirror {
          try await verifyMirror(mirror)
        } else {
          try await verifyRestored(journal)
          guard try NativeLabSafety.baseline(DisplayObserver.read(), external: external) == target
          else {
            throw NativeLabError.refused("The original arrangement was not restored.")
          }
        }
      } catch {
        // Never leave the panel off, and never record a validation for a run that failed.
        if suppressed {
          try? api.setEnabled(true, displayID: target.displayID, scope: .forAppOnly)
          try? await verifyRestored(journal)
        }
        try? report("backend-validation-aborted")
        throw error
      }

      try report("backend-validation-restored")
      let record = BackendValidation(
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        hardwareModel: BackendValidation.hardwareModel(), symbolName: symbol,
        evidence:
          "Verified off and on round trip on a \(mirror == nil ? "extended" : "mirrored") arrangement, with the observed layout restored."
      )
      try BackendValidationStore().save(record)
      print(
        """
        RESULT: the internal display was turned off and restored, and the observed arrangement matched.
        Recorded for \(record.hardwareModel) on \(record.osVersion) using \(symbol).
        This record only covers this Mac and this macOS build. Confirm you actually saw the
        internal screen go off and come back. If you did not, delete:
        \(BackendValidationStore.recordPath())
        """)
      fflush(stdout)
    }

    /// Suppression has to be observed, not assumed from a call that returned without error.
    /// A mirrored follower already reports inactive, so "not active" would be true before the
    /// call and would prove nothing. Absence counts, and inactivity only counts as a change.
    private func confirmSuppressed(
      target: PanelTarget, external: UInt32, mirror: NativeMirrorBaseline?, wasActive: Bool
    ) async throws {
      let deadline = ProcessInfo.processInfo.systemUptime + 3
      repeat {
        try await Task.sleep(for: .milliseconds(100))
        let current = DisplayObserver.read()
        guard current.enumerationError == nil else { continue }
        let entry = current.displays.first { $0.id == target.displayID }
        let panelSuppressed = entry == nil || (wasActive && entry?.active == false)
        let externalUsable =
          mirror?.externalUsable(current, external: external)
          ?? current.displays.contains { $0.id == external && $0.usableExternalCandidate }
        if panelSuppressed && externalUsable { return }
      } while ProcessInfo.processInfo.systemUptime < deadline
      throw NativeLabError.refused(
        "The internal panel was not observed off, so the backend is not validated.")
    }
  }
#endif
