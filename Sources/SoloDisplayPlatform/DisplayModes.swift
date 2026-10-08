import CoreGraphics
import Foundation
import SoloDisplayCore

/// What Sharp Text would make of one external display, for people to run and send in.
public struct DisplayModeReport: Codable, Sendable {
  public var displayID: UInt32
  public var vendor: UInt32
  public var product: UInt32
  public var mirrored: Bool
  public var current: DisplayModeSummary?
  public var native: ModeSize?
  public var publicModes: Int
  /// Nil when the private list could not be read on this Mac.
  public var privateModes: Int?
  public var verdict: SharpText.Verdict?
  /// Sizes below native with both a plain and a 2x mode at the current refresh rate.
  public var sharpSizes: [ModeSize]
}

/// Display modes from both catalogs. The private list decides what exists, because it holds the
/// 2x modes the public one hides. The public one decides what is native and what is current,
/// because those are documented there and are not trusted from an undocumented layout.
public enum DisplayModeCatalog {
  /// IOGraphics' kDisplayModeNativeFlag.
  static let nativeFlag: UInt32 = 0x0200_0000
  /// IOGraphics' kDisplayModeValidForMirroringFlag. The 2x modes System Settings never offers
  /// carry it and the ones it does offer do not, seen on a 1440p monitor on 2026-10-08.
  static let mirroringFlag: UInt32 = 0x0020_0000

  /// A 2x mode only a tool like Sharp Text puts a display in, because macOS keeps it for
  /// mirroring and never lists it. Readable from the current mode alone, so nothing has to
  /// remember who made the switch.
  public static func isHiddenSharp(_ mode: CGDisplayMode) -> Bool {
    isHiddenSharp(scale: summary(mode).scale, flags: mode.ioFlags)
  }

  static func isHiddenSharp(scale: Int, flags: UInt32) -> Bool {
    scale == 2 && flags & mirroringFlag != 0 && flags & nativeFlag == 0
  }

  public static func publicModes(_ displayID: UInt32) -> [CGDisplayMode] {
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    return CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? []
  }

  public static func summary(_ mode: CGDisplayMode) -> DisplayModeSummary {
    .init(
      width: mode.width, height: mode.height,
      scale: scale(
        width: mode.width, height: mode.height,
        pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight
      ),
      refreshRate: Int(mode.refreshRate.rounded()), number: Int32(mode.ioDisplayModeID),
      usable: mode.isUsableForDesktopGUI()
    )
  }

  public static func summary(_ mode: PrivateDisplayMode) -> DisplayModeSummary {
    .init(
      width: mode.width, height: mode.height,
      scale: mode.density == 2 ? 2 : mode.density == 1 ? 1 : 0,
      // The valid bit, the same one the hardware trial required.
      refreshRate: mode.frequency, number: mode.number, usable: mode.flags & 1 != 0
    )
  }

  public static func current(_ displayID: UInt32) -> DisplayModeSummary? {
    CGDisplayCopyDisplayMode(displayID).map(summary)
  }

  /// The sizes the public catalog flags as native.
  public static func nativeSizes(_ modes: [CGDisplayMode]) -> [ModeSize] {
    modes.filter { $0.ioFlags & nativeFlag != 0 }.map {
      .init(width: $0.pixelWidth, height: $0.pixelHeight)
    }
  }

  public static func report(_ displayID: UInt32, api: PrivateDisplayAPI) -> DisplayModeReport {
    let publicList = publicModes(displayID)
    let privateList = api.modes(displayID: displayID)
    let catalog = privateList.map { $0.map(summary) } ?? publicList.map(summary)
    let native = SharpText.native(flagged: nativeSizes(publicList), catalog: catalog)
    let current = current(displayID)
    return .init(
      displayID: displayID, vendor: CGDisplayVendorNumber(displayID),
      product: CGDisplayModelNumber(displayID),
      mirrored: CGDisplayIsInMirrorSet(displayID) != 0,
      current: current, native: native, publicModes: publicList.count,
      privateModes: privateList?.count,
      verdict: current.map { SharpText.verdict(current: $0, native: native, catalog: catalog) },
      sharpSizes: native.flatMap { native in
        current.map {
          SharpText.sizes(catalog: catalog, native: native, refreshRate: $0.refreshRate)
        }
      } ?? []
    )
  }

  /// Every online external display. Built-in panels are already Retina.
  public static func externalDisplays() -> [UInt32] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
  }

  static func scale(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) -> Int {
    guard width > 0, height > 0 else { return 0 }
    if pixelWidth == width, pixelHeight == height {
      return 1
    }
    return pixelWidth == 2 * width && pixelHeight == 2 * height ? 2 : 0
  }
}
