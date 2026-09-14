import Foundation
import Testing
@testable import SoloDisplayPlatform

@Test func onlyOneProcessCanHoldASessionLock() throws {
  // A private directory, not just a synthetic ID, isolates this from live and past sessions.
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let session = UInt32.random(in: 2_000_000_000 ..< 3_000_000_000)
  let first = try SessionWriterLock(loginID: session, name: "guardian", directory: directory)
  defer { first.release() }
  #expect(throws: (any Error).self) {
    _ = try SessionWriterLock(loginID: session, name: "guardian", directory: directory)
  }
  // Separate names are separate exclusions: one app and one guardian can coexist.
  let other = try SessionWriterLock(loginID: session, name: "instance", directory: directory)
  other.release()
  first.release()
  let second = try SessionWriterLock(loginID: session, name: "guardian", directory: directory)
  second.release()
}
