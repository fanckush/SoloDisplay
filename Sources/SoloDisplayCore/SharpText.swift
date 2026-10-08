/// A logical display size, in points.
public struct ModeSize: Codable, Hashable, Sendable {
  public var width: Int
  public var height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }

  var area: Int {
    width * height
  }
}

/// One display mode, reduced to what decides whether text on it can be sharper.
public struct DisplayModeSummary: Codable, Equatable, Sendable {
  public var width: Int
  public var height: Int
  /// Rendering pixels per point: 1 for a plain mode, 2 for HiDPI, 0 for anything else.
  public var scale: Int
  /// Rounded. Zero means macOS did not say, never a measured zero.
  public var refreshRate: Int
  /// Opaque, and only meaningful to the catalog it came from.
  public var number: Int32
  public var usable: Bool

  public init(
    width: Int, height: Int, scale: Int, refreshRate: Int, number: Int32, usable: Bool = true
  ) {
    self.width = width
    self.height = height
    self.scale = scale
    self.refreshRate = refreshRate
    self.number = number
    self.usable = usable
  }

  public var size: ModeSize {
    .init(width: width, height: height)
  }
}

/// Sharp Text's rule: below native resolution, a monitor should render at 2x, the way macOS
/// already treats 4K panels. At native it is left alone. The logical size never changes, so a
/// switch moves nothing on screen; only the rendering gets sharper.
public enum SharpText {
  public enum Verdict: Codable, Equatable, Sendable {
    /// Already rendering at 2x.
    case alreadySharp
    /// Native resolution is as sharp as this panel gets.
    case atNative
    /// The panel's native size could not be told apart from the modes on offer.
    case unknownNative
    /// Neither 1x nor 2x, which this rule does not reason about.
    case otherScale
    /// No 2x mode at this size and refresh rate. A slower 2x mode is not offered in its place:
    /// someone who bought a fast monitor cares more about the speed than about the text.
    case noTwin
    case wouldSwitch(to: DisplayModeSummary)
  }

  /// The panel's native size. The sizes macOS flags as native win; with none flagged, the
  /// largest plain mode stands in. More than one candidate means there is no answer.
  public static func native(flagged: [ModeSize], catalog: [DisplayModeSummary]) -> ModeSize? {
    let flaggedSizes = Set(flagged)
    if !flaggedSizes.isEmpty {
      return flaggedSizes.count == 1 ? flaggedSizes.first : nil
    }
    let plain = Set(catalog.filter { $0.scale == 1 && $0.usable }.map(\.size))
    guard let largest = plain.max(by: { $0.area < $1.area }) else { return nil }
    return plain.count(where: { $0.area == largest.area }) == 1 ? largest : nil
  }

  public static func verdict(
    current: DisplayModeSummary, native: ModeSize?, catalog: [DisplayModeSummary]
  ) -> Verdict {
    if current.scale == 2 {
      return .alreadySharp
    }
    guard current.scale == 1 else { return .otherScale }
    guard let native else { return .unknownNative }
    guard candidate(current, native: native) else { return .atNative }
    guard let twin = twin(of: current.size, refreshRate: current.refreshRate, in: catalog)
    else { return .noTwin }
    return .wouldSwitch(to: twin)
  }

  /// A plain mode below native: worth looking for a 2x twin. Decidable from the public catalog
  /// alone, which hides most twins, so it is a reason to look rather than a promise.
  public static func candidate(_ current: DisplayModeSummary, native: ModeSize?) -> Bool {
    guard current.scale == 1, let native else { return false }
    return below(current.size, native)
  }

  /// Every size below native that has both a plain and a 2x mode at this refresh rate, largest
  /// first. These are the sizes Sharp Text could make sharp on this monitor.
  public static func sizes(
    catalog: [DisplayModeSummary], native: ModeSize, refreshRate: Int
  ) -> [ModeSize] {
    let plain = Set(
      catalog.filter { $0.scale == 1 && $0.usable && $0.refreshRate == refreshRate }.map(\.size)
    )
    return plain
      .filter { below($0, native) && twin(of: $0, refreshRate: refreshRate, in: catalog) != nil }
      .sorted { $0.area > $1.area }
  }

  public static func twin(
    of size: ModeSize, refreshRate: Int, in catalog: [DisplayModeSummary]
  ) -> DisplayModeSummary? {
    catalog.first {
      $0.usable && $0.scale == 2 && $0.size == size && $0.refreshRate == refreshRate
    }
  }

  private static func below(_ size: ModeSize, _ native: ModeSize) -> Bool {
    size.width <= native.width && size.height <= native.height && size != native
  }
}
