import CoreFoundation
import Darwin
import Foundation
import IOKit

/// DDC/CI messages for reading and setting one VCP feature. The layout follows the VESA DDC/CI
/// standard: host-to-display checksums include the 0x6E destination and 0x51 source addresses,
/// and display-to-host checksums use the 0x50 virtual host address.
public enum DDCPacket {
  public static let brightness: UInt8 = 0x10
  static let displayAddress: UInt8 = 0x6E
  static let hostAddress: UInt8 = 0x51
  static let replyAddress: UInt8 = 0x50

  /// The payload after the source address, which the I2C call supplies itself.
  public static func getRequest(code: UInt8) -> [UInt8] {
    sealed([0x82, 0x01, code])
  }

  public static func setRequest(code: UInt8, value: UInt16) -> [UInt8] {
    sealed([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
  }

  /// Decodes a Get VCP Feature reply that starts with the display's 0x6E source address.
  public static func parseReply(_ bytes: [UInt8], code: UInt8) -> DDCValue? {
    guard bytes.count >= 11, bytes[0] == displayAddress, bytes[1] == 0x88, bytes[2] == 0x02,
          bytes[3] == 0x00, bytes[4] == code
    else { return nil }
    let checksum = bytes[0 ..< 10].reduce(replyAddress, ^)
    guard checksum == bytes[10] else { return nil }
    return DDCValue(
      current: UInt16(bytes[8]) << 8 | UInt16(bytes[9]),
      maximum: UInt16(bytes[6]) << 8 | UInt16(bytes[7])
    )
  }

  private static func sealed(_ body: [UInt8]) -> [UInt8] {
    body + [body.reduce(displayAddress ^ hostAddress, ^)]
  }
}

public struct DDCValue: Codable, Equatable, Sendable {
  public var current: UInt16
  public var maximum: UInt16
}

public enum DDCError: Error, CustomStringConvertible {
  case unavailable
  case noService(String)
  case write(Int32)
  case noReply
  public var description: String {
    switch self {
    case .unavailable: "IOAVService DDC calls are unavailable."
    case let .noService(controller): "No external DDC service for \(controller)."
    case let .write(code): "DDC write failed with IOReturn \(code)."
    case .noReply: "The display did not return a valid DDC reply."
    }
  }
}

/// The private IOAVService I2C calls that reach an external display on Apple silicon.
struct DDCCalls: @unchecked Sendable {
  typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
  typealias Transfer = @convention(c) (
    CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32
  ) -> Int32

  let create: Create?
  let read: Transfer?
  let write: Transfer?

  static let shared: DDCCalls = {
    // IOKit is already loaded, so the default search finds its exported symbols.
    let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
    return DDCCalls(
      create: dlsym(handle, "IOAVServiceCreateWithService")
        .map { unsafeBitCast($0, to: Create.self) },
      read: dlsym(handle, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: Transfer.self) },
      write: dlsym(handle, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: Transfer.self) }
    )
  }()
}

/// One external display's DDC connection. Calls can stall, so it is used from one serial queue
/// and never from the main thread.
public final class DDCChannel: @unchecked Sendable {
  static let chipAddress: UInt32 = 0x37
  /// Displays need time between a request and its reply.
  static let replyDelay: useconds_t = 50000

  private let service: CFTypeRef
  private let calls: DDCCalls

  init(service: CFTypeRef, calls: DDCCalls) {
    self.service = service
    self.calls = calls
  }

  public func get(code: UInt8, attempts: Int = 3) throws -> DDCValue {
    for _ in 0 ..< attempts {
      var request = DDCPacket.getRequest(code: code)
      guard transfer(calls.write, &request) == 0 else { continue }
      usleep(Self.replyDelay)
      var reply = [UInt8](repeating: 0, count: 12)
      guard transfer(calls.read, &reply) == 0 else { continue }
      if let value = DDCPacket.parseReply(reply, code: code) {
        return value
      }
    }
    throw DDCError.noReply
  }

  public func set(code: UInt8, value: UInt16) throws {
    var request = DDCPacket.setRequest(code: code, value: value)
    let result = transfer(calls.write, &request)
    guard result == 0 else { throw DDCError.write(result) }
  }

  private func transfer(_ call: DDCCalls.Transfer?, _ bytes: inout [UInt8]) -> Int32 {
    guard let call else { return -1 }
    let count = UInt32(bytes.count)
    return bytes.withUnsafeMutableBytes { buffer in
      call(service, Self.chipAddress, UInt32(DDCPacket.hostAddress), buffer.baseAddress!, count)
    }
  }
}

/// Finds the DDC service for an external display. A service is tied to a display through the
/// SoC display controller both hang off: the service's parent is named `dispext0:...`, and the
/// display's framebuffer service sits under the `dispext0` controller.
public enum IOAVServiceDDC {
  /// The service class that exposes DDC for an output.
  static let serviceClass = "DCPAVServiceProxy"

  public static var available: Bool {
    let calls = DDCCalls.shared
    return calls.create != nil && calls.read != nil && calls.write != nil
  }

  /// The display controller behind each display, for displays that can be told apart for
  /// certain. Built-in panels and displays outside the SoC pipeline are left out.
  public static func controllers(forDisplays ids: [UInt32]) -> [UInt32: String] {
    let evidence = DisplayTransportClassifier.evidence(for: ids.map { ($0, false) })
    var found: [UInt32: String] = [:]
    for item in evidence where item.transport == .native {
      guard let index = item.providerChain
        .firstIndex(of: DisplayTransportClassifier.displayControllerClass),
        index < item.providerNames.count
      else { continue }
      found[item.displayID] = item.providerNames[index]
    }
    return found
  }

  /// Controllers, such as `dispext0`, that have an external DDC service.
  public static func externalControllers() -> [String] {
    var names: [String] = []
    forEachExternalService { controller, _ in names.append(controller) }
    return names
  }

  public static func channel(controller: String) throws -> DDCChannel {
    let calls = DDCCalls.shared
    guard let create = calls.create, available else { throw DDCError.unavailable }
    var channel: DDCChannel?
    forEachExternalService { name, service in
      guard channel == nil, name == controller,
            let reference = create(kCFAllocatorDefault, service)?.takeRetainedValue()
      else { return }
      channel = DDCChannel(service: reference, calls: calls)
    }
    guard let channel else { throw DDCError.noService(controller) }
    return channel
  }

  private static func forEachExternalService(_ body: (String, io_service_t) -> Void) {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator
      ) == KERN_SUCCESS
    else { return }
    defer { IOObjectRelease(iterator) }
    while case let service = IOIteratorNext(iterator), service != 0 {
      defer { IOObjectRelease(service) }
      let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, nil, 0)?
        .takeRetainedValue() as? String
      guard location == "External", let controller = controllerName(service) else { continue }
      body(controller, service)
    }
  }

  private static func controllerName(_ service: io_service_t) -> String? {
    var parent: io_registry_entry_t = 0
    guard IORegistryEntryGetParentEntry(service, "IOService", &parent) == KERN_SUCCESS,
          parent != 0
    else { return nil }
    defer { IOObjectRelease(parent) }
    var buffer = [CChar](repeating: 0, count: 128)
    guard IORegistryEntryGetName(parent, &buffer) == KERN_SUCCESS else { return nil }
    let name = String(
      bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8
    ) ?? ""
    guard let prefix = name.split(separator: ":").first,
          prefix.hasPrefix(DisplayTransportClassifier.displayControllerPrefix)
    else { return nil }
    return String(prefix)
  }
}
