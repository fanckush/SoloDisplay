import CoreGraphics
import Darwin
import Foundation

/// The ABI follows the reference implementation. Its presence is not a compatibility guarantee.
public final class PrivateDisplayAPI {
  private typealias Configure = @convention(c) (OpaquePointer?, UInt32, Int32) -> Int32
  private let handle: UnsafeMutableRawPointer?
  private let configure: Configure?
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
