import Foundation
import LidlessCore
import Synchronization

/// Newline-delimited JSON frames on an inherited private pipe. Bounds are enforced before
/// decoding: an oversized or unparseable frame closes the link instead of being skipped.
public struct ProtectionFrameBuffer: Sendable {
  public static let maximumFrame = 4_096
  public static let maximumPending = 16_384

  private var pending = Data()
  private var ended = false
  public private(set) var failure: ProtectionRejection?

  public init() {}

  public var isClosed: Bool { failure != nil }

  public mutating func receive(_ data: Data) {
    guard failure == nil, !ended else { return }
    if data.isEmpty {
      ended = true
      return
    }
    guard pending.count + data.count <= Self.maximumPending else {
      failure = .malformed
      return
    }
    pending.append(data)
  }

  /// Returns the next complete frame, nil while one is still arriving, and throws once the
  /// peer is gone or has sent something the protocol does not define.
  public mutating func next() throws -> ProtectionMessage? {
    if let failure { throw failure }
    guard let end = pending.firstIndex(of: 0x0A) else {
      guard pending.count <= Self.maximumFrame else {
        failure = .malformed
        throw ProtectionRejection.malformed
      }
      guard !ended else { throw ProtectionRejection.disconnected }
      return nil
    }
    let frame = pending[pending.startIndex..<end]
    pending.removeSubrange(pending.startIndex...end)
    guard frame.count <= Self.maximumFrame,
      let message = try? JSONDecoder().decode(ProtectionMessage.self, from: Data(frame))
    else {
      failure = .malformed
      throw ProtectionRejection.malformed
    }
    return message
  }

  public static func encode(_ message: ProtectionMessage) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(message)
    guard data.count < maximumFrame else { throw ProtectionRejection.malformed }
    data.append(0x0A)
    return data
  }
}

/// One peer's end of the pair. Reading is asynchronous; the owner polls on its own serial lane
/// so a message never executes a display change inside a callback.
public final class ProtectionLink: Sendable {
  private let buffer = Mutex(ProtectionFrameBuffer())
  private let input: FileHandle
  private let output: FileHandle

  public init(input: FileHandle, output: FileHandle) {
    self.input = input
    self.output = output
    input.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      self?.buffer.withLock { $0.receive(data) }
      if data.isEmpty { handle.readabilityHandler = nil }
    }
  }

  public func poll() throws -> ProtectionMessage? { try buffer.withLock { try $0.next() } }

  public func send(_ message: ProtectionMessage) throws {
    try output.write(contentsOf: ProtectionFrameBuffer.encode(message))
  }

  public func stop() { input.readabilityHandler = nil }
  deinit { input.readabilityHandler = nil }
}
