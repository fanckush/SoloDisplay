import Darwin

/// What this Mac is built on, where that changes what SoloDisplay can promise.
public enum Chip {
  /// The base M3 drives a monitor beside its own screen through a route that does not reliably
  /// hand the laptop screen back. Turning it on again can hang WindowServer until macOS kills
  /// it, or fail until a restart. The M3 Pro and Max, and the chips before and after, are not
  /// affected. Issue #9.
  public static let turningOnCanFreeze = turningOnCanFreeze(brand: brand ?? "")

  static func turningOnCanFreeze(brand: String) -> Bool {
    brand == "Apple M3"
  }

  /// Such as "Apple M3 Pro".
  static var brand: String? {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0
    else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return nil }
    return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  }
}
