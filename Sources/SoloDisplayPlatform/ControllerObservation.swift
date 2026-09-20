import SoloDisplayCore

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
/// authority, and it never guesses that a display it cannot see is one SoloDisplay turned off.
public enum ControllerObservation {
  public static func environment(
    _ reading: PlatformReading, power: Power, owned: OwnedPanelContext? = nil,
    suppressedExternals: [PanelTarget] = []
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
      nativeExternalAvailable: nativeExternal(reading, reliable: reliable,
                                              maintainingSuppression: state == .disabled && owned?
                                                .disableReturned == true),
      supportedTopology: topology(
        reading, reliable: reliable, internalPresent: internalDisplay != nil,
        panelOwnedAndAbsent: state == .disabled
      ),
      externals: externals(reading, reliable: reliable, suppressed: suppressedExternals),
      visibleDisplays: visibleDisplays(reading, reliable: reliable, panelState: state)
    )
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
            !$0.mirrored || $0.id == follower.id || $0.mirrorSourceID == sourceID || $0
              .id == sourceID
          })
    else { return .no }
    return .yes
  }

  /// Every monitor with a DDC endpoint: the live ones, and the ones this app turned off, which
  /// left CoreGraphics entirely and are known only from what it recorded about them. A monitor
  /// is read as off only while it is actually absent: a record says what is owed, never what the
  /// hardware is doing, and reading it as the hardware would leave a monitor on for ever because
  /// nothing would ever ask for it to be turned off.
  static func externals(
    _ reading: PlatformReading, reliable: Bool, suppressed: [PanelTarget]
  ) -> [ExternalCandidate] {
    guard reliable else { return [] }
    var found: [ExternalCandidate] = []
    if let bootID = reading.bootID, let loginID = reading.loginID {
      for display in reading.displays where !display.builtIn {
        guard let controller = reading.controllers[display.id], let uuid = display.uuid,
              !found.contains(where: { $0.target.displayUUID == uuid })
        else { continue }
        // Turning it off is only safe while it is a real wired output that is not itself
        // following another screen. A screen that follows this one survives on its own.
        let suppressible = display.online && !display.asleep
          && display.transport == DisplayTransport.native.rawValue
          && display.mirrorSourceID == nil && display.modeAvailable
        found.append(.init(
          target: .init(
            displayID: display.id, displayUUID: uuid, bootID: bootID, loginID: loginID,
            kind: .external, controller: controller
          ),
          suppressible: suppressible, suppressed: false
        ))
      }
    }
    // Owed and gone from the inventory, which is what this app turning one off looks like.
    for target in suppressed
      where !found.contains(where: { $0.target.displayUUID == target.displayUUID }) {
      found.append(.init(target: target, suppressible: false, suppressed: true))
    }
    return found
  }

  /// Screens a person could look at. A mirror follower is one of them: it is showing something.
  static func visibleDisplays(
    _ reading: PlatformReading, reliable: Bool, panelState: PanelState
  ) -> Int {
    guard reliable else { return 0 }
    return reading.displays.count {
      guard $0.online, !$0.asleep, $0.active || $0.mirrorSourceID != nil else { return false }
      return $0.builtIn ? panelState != .disabled : true
    }
  }

  /// Transport classification is the sole authority here. An active flag, a display name, and
  /// an operator's attestation in a lab are none of them evidence of a native wired output.
  static func nativeExternal(_ reading: PlatformReading, reliable: Bool,
                             maintainingSuppression: Bool = false) -> Fact {
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
        || ((maintainingSuppression || ($0.active && !$0.asleep))
          && $0.mirrorSourceID == nil && $0.online && $0.modeAvailable && $0.width > 0
          && $0.height > 0)
    }) ? .yes : .no
  }
}
