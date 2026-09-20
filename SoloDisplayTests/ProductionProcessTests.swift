import Foundation
import Testing
@testable import SoloDisplay

struct ProductionProcessTests {
  @Test func aNormalLaunchBecomesTheApp() throws {
    #expect(try ProductionLaunch.role(arguments: [], pipedStandardStreams: false) == .app)
    #expect(
      try ProductionLaunch.role(arguments: ["--diagnostics"], pipedStandardStreams: false) == .app
    )
    // Inherited pipes without an argument are not a claim to a child role.
    #expect(try ProductionLaunch.role(arguments: [], pipedStandardStreams: true) == .app)
  }

  @Test func childRolesRequireActualInheritedPipes() throws {
    for (argument, role) in [
      (ProductionLaunch.guardianArgument, ProductionRole.guardian),
      (ProductionLaunch.workerArgument, .worker)
    ] {
      #expect(try ProductionLaunch.role(arguments: [argument], pipedStandardStreams: true) == role)
      // A command-line assertion alone can never establish the pairing.
      #expect(throws: ProductionLaunchError.self) {
        try ProductionLaunch.role(arguments: [argument], pipedStandardStreams: false)
      }
    }
  }

  @Test func onlyOneRoleCanBeSelected() {
    #expect(throws: ProductionLaunchError.self) {
      try ProductionLaunch.role(
        arguments: [ProductionLaunch.guardianArgument, ProductionLaunch.workerArgument],
        pipedStandardStreams: true
      )
    }
  }

  @Test func runningReadOnlyMustBeAskedForExplicitly() throws {
    #expect(
      try ProductionLaunch.role(
        arguments: [ProductionLaunch.unprotectedArgument], pipedStandardStreams: false
      )
        == .unprotected
    )
  }

  @Test func productionParsingNeverAcceptsALabCommandOrAnyOtherArgument() {
    for argument in ["--lab-check", "--solodisplay-controller", "--external", "--anything"] {
      #expect(throws: ProductionLaunchError.self) {
        try ProductionLaunch.role(arguments: [argument], pipedStandardStreams: true)
      }
    }
  }
}

/// A pipe carries bytes, not messages. Once more than one kind of message travels this pipe, a
/// chunk boundary in the wrong place would otherwise be read as the wrong message, or as none.
struct GuardianLineReaderTests {
  @Test func aMessageSplitAcrossTwoChunksIsStillOneMessage() {
    let reader = GuardianLineReader()
    #expect(reader.lines(Data("rel".utf8)).isEmpty)
    let lines = reader.lines(Data("ease\n".utf8))
    #expect(lines.compactMap { String(bytes: $0, encoding: .utf8) } == ["release"])
  }

  @Test func severalMessagesInOneChunkAreAllRead() {
    let reader = GuardianLineReader()
    let lines = reader.lines(Data("one\ntwo\nthree\n".utf8))
    #expect(lines.compactMap { String(bytes: $0, encoding: .utf8) } == ["one", "two", "three"])
  }

  @Test func anUnfinishedMessageIsNotAMessageYet() {
    let reader = GuardianLineReader()
    #expect(reader.lines(Data("release".utf8)).isEmpty)
  }

  @Test func aLineThatNeverEndsIsDroppedRatherThanBuffered() {
    let reader = GuardianLineReader()
    let flood = Data(repeating: 0x61, count: GuardianLineReader.limit + 1)
    #expect(reader.lines(flood).isEmpty)
    // The flood was dropped, so a following message is still read correctly.
    #expect(reader.lines(Data("release\n".utf8)).count == 1)
  }
}
