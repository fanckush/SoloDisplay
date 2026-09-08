import CoreGraphics
import Foundation
import IOKit

/// How a display reaches this Mac. Only `native` authorizes turning the internal panel off.
/// `unclassified` is the default and is never treated as a quiet yes.
public enum DisplayTransport: String, Codable, Equatable, Sendable {
  case native, virtual, unclassified
}

/// How confidently a CoreGraphics display was tied to an IOKit display service.
public enum TransportMatch: String, Codable, Equatable, Sendable {
  case none, vendor, vendorModel, vendorModelSerial
}

/// The runtime facts a classification is made from, kept verbatim so a decision can be argued
/// with rather than trusted. Display names and operator attestation are deliberately absent.
public struct TransportEvidence: Codable, Equatable, Sendable {
  public var displayID: UInt32
  public var builtIn: Bool
  public var vendor: UInt32
  public var model: UInt32
  public var serial: UInt32
  public var unit: UInt32
  public var match: TransportMatch
  /// Class names from the display service up through its providers, nearest first.
  public var providerChain: [String]
  /// Registry entry names for the same chain. The SoC display controllers are named `disp*`.
  public var providerNames: [String]

  public var transport: DisplayTransport { DisplayTransportClassifier.classify(self) }
}

public enum DisplayTransportClassifier {
  /// Vendor identifier meaning "unknown" in IOGraphics. Software displays commonly report it.
  static let unknownVendor: UInt32 = 0x756E_6B6E
  /// The service class that publishes display identity on this hardware family.
  static let displayServiceClass = "IOMobileFramebufferShim"
  /// The SoC display controller a real output hangs off, named `disp0`, `dispext0` and so on.
  static let displayControllerClass = "AppleARMIODevice"
  static let displayControllerPrefix = "disp"

  /// Native means: correlated to a display service that hangs off the SoC display pipeline.
  /// A DisplayLink, wireless, or virtual display is not published through that pipeline, so it
  /// cannot reach this verdict. Nothing here is inferred from a display's name or its flags.
  public static func classify(_ evidence: TransportEvidence) -> DisplayTransport {
    guard evidence.match != .none else { return .unclassified }
    let controllerIndex = evidence.providerChain.firstIndex(of: displayControllerClass)
    if evidence.providerChain.contains(displayServiceClass), let controllerIndex,
      controllerIndex < evidence.providerNames.count,
      evidence.providerNames[controllerIndex].hasPrefix(displayControllerPrefix)
    {
      return .native
    }
    // A software display usually cannot supply a real vendor. That is a hint, not a verdict.
    if evidence.vendor == unknownVendor || evidence.vendor == 0 { return .virtual }
    return .unclassified
  }

  /// Correlates CoreGraphics displays to IOKit display services and records what it found.
  public static func evidence(for displays: [(id: UInt32, builtIn: Bool)]) -> [TransportEvidence] {
    let services = displayServices()
    return displays.map { display in
      let vendor = CGDisplayVendorNumber(display.id)
      let model = CGDisplayModelNumber(display.id)
      let serial = CGDisplaySerialNumber(display.id)
      // Prefer the most specific correlation available, and record which one was used.
      var match = TransportMatch.none
      var service = services.first {
        $0.vendor == vendor && $0.model == model && $0.serial == serial && $0.serial != 0
      }
      if service != nil {
        match = .vendorModelSerial
      } else if let byModel = services.first(where: { $0.vendor == vendor && $0.model == model }) {
        service = byModel
        match = .vendorModel
      } else {
        let byVendor = services.filter { $0.vendor == vendor }
        if byVendor.count == 1, services.filter({ $0.vendor == vendor }).count == 1 {
          service = byVendor.first
          match = .vendor
        }
      }
      return .init(
        displayID: display.id, builtIn: display.builtIn, vendor: vendor, model: model,
        serial: serial, unit: CGDisplayUnitNumber(display.id), match: match,
        providerChain: service?.providerChain ?? [],
        providerNames: service?.providerNames ?? [])
    }
  }

  private struct Service {
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32
    var providerChain: [String]
    var providerNames: [String]
  }

  private static func displayServices() -> [Service] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching(displayServiceClass), &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }
    var found: [Service] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
      defer { IOObjectRelease(service) }
      guard
        let attributes = IORegistryEntryCreateCFProperty(
          service, "DisplayAttributes" as CFString, nil, 0)?.takeRetainedValue()
          as? [String: Any],
        let product = attributes["ProductAttributes"] as? [String: Any]
      else { continue }
      let chain = ancestry(service)
      found.append(
        .init(
          vendor: number(product, "LegacyManufacturerID"), model: number(product, "ProductID"),
          serial: number(product, "SerialNumber"), providerChain: chain.classes,
          providerNames: chain.names))
    }
    return found
  }

  private static func number(_ info: [String: Any], _ key: String) -> UInt32 {
    guard let value = info[key] as? NSNumber else { return 0 }
    let wide = value.uint64Value
    // A panel identifier wider than the CoreGraphics field cannot correlate; do not truncate it.
    return wide <= UInt64(UInt32.max) ? UInt32(wide) : 0
  }

  private static func ancestry(_ service: io_service_t, depth: Int = 10)
    -> (classes: [String], names: [String])
  {
    var classes: [String] = []
    var names: [String] = []
    var current = service
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }
    for _ in 0..<depth {
      classes.append(entryText { IOObjectGetClass(current, $0) })
      names.append(entryText { IORegistryEntryGetName(current, $0) })
      var parent: io_registry_entry_t = 0
      guard IORegistryEntryGetParentEntry(current, "IOService", &parent) == KERN_SUCCESS,
        parent != 0
      else { return (classes, names) }
      IOObjectRelease(current)
      current = parent
    }
    return (classes, names)
  }

  private static func entryText(_ read: (UnsafeMutablePointer<CChar>) -> kern_return_t) -> String {
    var buffer = [CChar](repeating: 0, count: 128)
    guard read(&buffer) == KERN_SUCCESS else { return "" }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
