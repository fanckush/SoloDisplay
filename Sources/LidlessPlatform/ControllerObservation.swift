import LidlessCore

/// What this process knows about a panel it may have turned off. Absence is only ever read as
/// suppression with both of these: live ownership of that exact target, and a disable request
/// for it that actually returned.
public struct OwnedPanelContext: Equatable, Sendable {
  public var target: PanelTarget
  public var disableReturned: Bool

  public init(target: PanelTarget, disableReturned: Bool) {
    self.target = target
    self.disableReturned = disableReturned
  }
}

/// Normalizes a platform reading into controller evidence. It never upgrades a raw flag into
/// authority, and it never guesses that a display it cannot see is one Lidless turned off.
public enum ControllerObservation {
  public static func environment(
    _ reading: PlatformReading, power: Power, owned: OwnedPanelContext? = nil
  ) -> Environment {
    // An empty inventory is normally unusable evidence. It is coherent in exactly one case:
    // this process turned the only internal panel off and no external remains to enumerate.
    let ownedAbsence =
      owned?.disableReturned == true && reading.bootID == owned?.target.bootID
      && reading.loginID == owned?.target.loginID
    let reliable =
      reading.enumerationError == nil && (!reading.displays.isEmpty || ownedAbsence)
    let present = reliable ? reading.internalTarget : nil
    let internalDisplay = reading.displays.first { $0.builtIn }
    let state = panelState(reading, reliable: reliable, target: present, owned: owned)
    // A panel this process turned off has no live entry to read an identity from. Ownership
    // supplies it, and only once absence has already been established as our own suppression.
    let target = present ?? (state == .disabled ? owned?.target : nil)
    return .init(
      panel: target, panelState: state, power: power, lid: reading.lid,
      foregroundSession: reading.foregroundSession,
      nativeExternalAvailable: nativeExternal(reading, reliable: reliable),
      supportedTopology: topology(
        reading, reliable: reliable, internalPresent: internalDisplay != nil,
        panelOwnedAndAbsent: state == .disabled),
      backendValidated: reading.backendValidated ? .yes : .unknown)
  }

  static func panelState(
    _ reading: PlatformReading, reliable: Bool, target: PanelTarget?, owned: OwnedPanelContext?
  ) -> PanelState {
    guard reliable else { return .unknown }
    if let display = reading.displays.first(where: \.builtIn) {
      // A mirror follower is normally reported inactive. That is presence, not suppression.
      let drivable =
        display.online && !display.asleep && (display.active || display.mirrorSourceID != nil)
      return drivable && target != nil ? .enabled : .unknown
    }
    guard let owned, owned.disableReturned, reading.bootID == owned.target.bootID,
      reading.loginID == owned.target.loginID
    else { return .unknown }
    return .disabled
  }

  /// Supported arrangements are an unmirrored desktop, or the internal panel following one
  /// present external source. An internal mirror source and unresolvable sets stay unavailable.
  static func topology(
    _ reading: PlatformReading, reliable: Bool, internalPresent: Bool, panelOwnedAndAbsent: Bool
  ) -> Fact {
    guard reliable else { return .unknown }
    guard reading.mirroringDetected else { return .yes }
    guard let follower = reading.displays.first(where: \.builtIn) else {
      guard panelOwnedAndAbsent else { return .unknown }
      // Only externals remain. Each mirrored one must be a source, not a follower of a ghost.
      return reading.displays.allSatisfy { !$0.mirrored || $0.mirrorSourceID == nil } ? .yes : .no
    }
    guard internalPresent, follower.mirrored, let sourceID = follower.mirrorSourceID,
      let source = reading.displays.first(where: { $0.id == sourceID }), !source.builtIn,
      source.mirrorSourceID == nil,
      reading.displays.allSatisfy({
        !$0.mirrored || $0.id == follower.id || $0.mirrorSourceID == sourceID || $0.id == sourceID
      })
    else { return .no }
    return .yes
  }

  /// Transport classification is the sole authority here. An active flag, a display name, and
  /// an operator's attestation in a lab are none of them evidence of a native wired output.
  static func nativeExternal(_ reading: PlatformReading, reliable: Bool) -> Fact {
    guard reliable else { return .unknown }
    let externals = reading.displays.filter { !$0.builtIn && $0.online }
    guard !externals.isEmpty else { return .no }
    if externals.contains(where: { $0.transport == DisplayTransport.unclassified.rawValue }) {
      return .unknown
    }
    guard externals.allSatisfy({ $0.transport == DisplayTransport.native.rawValue }) else {
      return .no
    }
    // A mirror source is never a "usable candidate" because it is itself mirrored, so it is
    // accepted separately. Display sleep leaves a monitor online and connected, and system-wide
    // display sleep is not a reason to put a suppressed panel back, so asleep is not excluded
    // here. An actually absent external is, because it disappears from the inventory.
    return externals.contains(where: {
      $0.usableExternalCandidate
        || ($0.mirrorSourceID == nil && $0.online && $0.modeAvailable && $0.width > 0
          && $0.height > 0)
    }) ? .yes : .no
  }
}
