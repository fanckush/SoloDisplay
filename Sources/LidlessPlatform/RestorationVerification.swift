import LidlessCore

/// Restoration means both a usable internal panel and preservation of observable configuration.
/// It does not repair external settings. A missing external is an interruption, not permission
/// to recreate a mirror pointing at a display that is no longer connected.
public enum RestorationVerification {
  public static func matches(_ record: ProductionRecord, reading: PlatformReading) -> Fact {
    guard reading.enumerationError == nil, reading.bootID == record.target.bootID,
      reading.loginID == record.target.loginID, reading.lid == .open,
      reading.foregroundSession == .yes,
      let panel = reading.displays.first(where: { $0.id == record.target.displayID }),
      panel.builtIn, panel.uuid == record.target.displayUUID, panel.online, !panel.asleep,
      panel.active || panel.mirrorSourceID != nil else { return .unknown }
    let before = record.topology
    guard before.contains(where: { $0.builtIn && $0.uuid == panel.uuid }) else { return .unknown }
    let oldIDs = Set(before.map(\.id))
    let newIDs = Set(reading.displays.map(\.id))
    guard newIDs.isSubset(of: oldIDs) else { return .no }
    for current in reading.displays {
      guard let original = before.first(where: { $0.id == current.id }),
        original.uuid == current.uuid else { return .no }
      if let source = current.mirrorSourceID, !newIDs.contains(source) { return .no }
      if oldIDs == newIDs {
        guard original.mirrored == current.mirrored,
          original.mirrorSourceID == current.mirrorSourceID,
          original.width == current.width, original.height == current.height,
          original.originX == current.originX, original.originY == current.originY,
          original.modeAvailable == current.modeAvailable else { return .no }
      } else if let oldSource = original.mirrorSourceID, !newIDs.contains(oldSource) {
        guard current.mirrorSourceID == nil else { return .no }
      }
    }
    return .yes
  }
}
