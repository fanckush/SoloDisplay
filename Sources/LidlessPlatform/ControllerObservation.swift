import LidlessCore

/// Conservative normalization for shadow execution. This is not a suppression verifier:
/// absence and inactive mirror followers must never be translated into "disabled".
public enum ControllerObservation {
  public static func environment(_ reading: PlatformReading, power: Power) -> Environment {
    let reliable = reading.enumerationError == nil && !reading.displays.isEmpty
    let target = reliable ? reading.internalTarget : nil
    let internalDisplay = reading.displays.first { $0.builtIn }
    let panelEnabled =
      target != nil && internalDisplay?.active == true
      && internalDisplay?.online == true && internalDisplay?.asleep == false
    return .init(
      panel: target, panelState: reliable && panelEnabled ? .enabled : .unknown,
      power: power, lid: reading.lid, foregroundSession: reading.foregroundSession,
      // Transport labels and CG active flags cannot establish a native physical output.
      nativeExternalAvailable: .unknown,
      supportedTopology: reliable && reading.mirroringDetected ? .no : .unknown,
      // Deliberately do not elevate the raw symbol or lab result into runtime authority.
      backendValidated: .unknown)
  }
}
