import CoreGraphics
import Darwin
import Foundation

/// The ABI follows the reference implementation. Its presence is not a compatibility guarantee.
public final class PrivateDisplayAPI {
  private typealias Configure = @convention(c) (OpaquePointer?, UInt32, Int32) -> Int32
  private typealias CountModes = @convention(c) (UInt32, UnsafeMutablePointer<Int32>) -> Void
  private typealias DescribeMode = @convention(c) (UInt32, Int32, UnsafeMutableRawPointer, Int32)
    -> Void
  private typealias ConfigureMode = @convention(c) (OpaquePointer?, UInt32, Int32) -> Void
  private let handle: UnsafeMutableRawPointer?
  private let configure: Configure?
  private let countModes: CountModes?
  private let describeMode: DescribeMode?
  private let configureMode: ConfigureMode?
  public let symbolName: String?

  public init() {
    let library = dlopen(
      "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL
    )
    handle = library
    var found: Configure?
    var name: String?
    // Never search the global namespace when opening the library fails.
    if let library {
      for candidate in ["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"] {
        if let symbol = dlsym(library, candidate) {
          found = unsafeBitCast(symbol, to: Configure.self)
          name = candidate
          break
        }
      }
    }
    configure = found
    symbolName = name
    /// The CGS names first: they are the ones the HiDPI trial was run against.
    func lookup<T>(_ names: [String], as _: T.Type) -> T? {
      guard let library else { return nil }
      for name in names {
        if let symbol = dlsym(library, name) {
          return unsafeBitCast(symbol, to: T.self)
        }
      }
      return nil
    }
    countModes = lookup(
      ["CGSGetNumberOfDisplayModes", "SLSGetNumberOfDisplayModes"], as: CountModes.self
    )
    describeMode = lookup(
      ["CGSGetDisplayModeDescriptionOfLength", "SLSGetDisplayModeDescriptionOfLength"],
      as: DescribeMode.self
    )
    configureMode = lookup(
      ["CGSConfigureDisplayMode", "SLSConfigureDisplayMode"], as: ConfigureMode.self
    )
  }

  deinit {
    if let handle {
      dlclose(handle)
    }
  }

  public func setEnabled(_ enabled: Bool, displayID: UInt32, scope: CGConfigureOption) throws {
    guard let configure else { throw DisplayAPIError.unavailable }
    var transaction: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&transaction)
    guard begin == .success else { throw DisplayAPIError.call("begin", begin.rawValue) }
    let result = configure(transaction, displayID, enabled ? 1 : 0)
    guard result == CGError.success.rawValue else {
      CGCancelDisplayConfiguration(transaction)
      throw DisplayAPIError.call("configure", result)
    }
    // Complete consumes the transaction even if it fails.
    let complete = CGCompleteDisplayConfiguration(transaction, scope)
    guard complete == .success else { throw DisplayAPIError.call("complete", complete.rawValue) }
  }

  /// Every mode WindowServer knows for a display, including 2x modes that the public catalog and
  /// System Settings leave out. Nil when the symbols are missing or the answer is implausible.
  public func modes(displayID: UInt32) -> [PrivateDisplayMode]? {
    guard let countModes, let describeMode else { return nil }
    var count: Int32 = 0
    countModes(displayID, &count)
    guard (1 ... 10000).contains(count) else { return nil }
    var modes: [PrivateDisplayMode] = []
    let buffer = UnsafeMutableRawBufferPointer.allocate(
      byteCount: PrivateDisplayMode.recordLength, alignment: 8
    )
    defer { buffer.deallocate() }
    for index in 0 ..< count {
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      describeMode(displayID, index, buffer.baseAddress!, Int32(PrivateDisplayMode.recordLength))
      guard let mode = PrivateDisplayMode.decode(UnsafeRawBufferPointer(buffer)) else { continue }
      modes.append(mode)
    }
    return modes
  }

  /// Selects a mode by its private number. The call reports nothing back, so whether the display
  /// is now in that mode is only ever known from a fresh public reading afterwards.
  public func setMode(_ number: Int32, displayID: UInt32, scope: CGConfigureOption) throws {
    guard let configureMode else { throw DisplayAPIError.unavailable }
    var transaction: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&transaction)
    guard begin == .success else { throw DisplayAPIError.call("begin", begin.rawValue) }
    configureMode(transaction, displayID, number)
    let complete = CGCompleteDisplayConfiguration(transaction, scope)
    guard complete == .success else { throw DisplayAPIError.call("complete", complete.rawValue) }
  }
}

/// One record from the private mode list. The layout is undocumented and follows the reference
/// implementations: only the fields read here are known, the rest is padding of unknown meaning.
public struct PrivateDisplayMode: Codable, Equatable, Sendable {
  static let recordLength = 212

  public var number: Int32
  public var flags: UInt32
  public var width: Int
  public var height: Int
  public var depth: Int
  public var frequency: Int
  public var density: Float

  /// Nil for a record of the wrong length or one that cannot be a real mode, which is also how
  /// a changed layout would show up.
  static func decode(_ bytes: UnsafeRawBufferPointer) -> PrivateDisplayMode? {
    guard bytes.count == recordLength else { return nil }
    let mode = PrivateDisplayMode(
      number: bytes.loadUnaligned(fromByteOffset: 0, as: Int32.self),
      flags: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
      width: Int(bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
      height: Int(bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
      depth: Int(bytes.loadUnaligned(fromByteOffset: 16, as: UInt32.self)),
      frequency: Int(bytes.loadUnaligned(fromByteOffset: 190, as: UInt16.self)),
      density: bytes.loadUnaligned(fromByteOffset: 208, as: Float.self)
    )
    guard (1 ... 32768).contains(mode.width), (1 ... 32768).contains(mode.height),
          mode.density.isFinite, mode.density > 0, mode.density <= 8
    else { return nil }
    return mode
  }
}

public enum DisplayAPIError: Error, CustomStringConvertible {
  case unavailable
  case call(String, Int32)
  public var description: String {
    switch self {
    case .unavailable: "Private display API unavailable."
    case let .call(stage, code):
      "Display operation failed at \(stage), code \(code). The physical outcome must be checked."
    }
  }
}
