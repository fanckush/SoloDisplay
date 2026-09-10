#if DEBUG
  import Darwin
  import Foundation
  import SoloDisplayCore
  import SoloDisplayPlatform
  import Testing
  @testable import SoloDisplay

  @MainActor
  struct NativeExitLabTests {
    @Test func unplugExperimentSeparatesSupervisorWriterAndRehearsal() throws {
      let options = ["--external", "5", "--journal", "/tmp/unplug.json", "--native-wired-attested"]
      for rehearsal in [false, true] {
        let suffix = rehearsal ? "-rehearsal" : ""
        #expect(
          try NativeLabCommand.parse(["--lab-unplug" + suffix] + options)
            == .failure(
              external: 5, journal: "/tmp/unplug.json", ending: .unplug, rehearsal: rehearsal
            )
        )
        #expect(
          try NativeLabCommand.parse(["--lab-unplug-writer" + suffix] + options)
            == .unplugWriter(external: 5, journal: "/tmp/unplug.json", rehearsal: rehearsal)
        )
      }
      #expect(throws: (any Error).self) {
        try NativeLabCommand.parse(["--lab-unplug"] + options.dropLast())
      }
    }

    @Test func contactFailureModesKeepRehearsalsExplicit() throws {
      let options = ["--external", "5", "--journal", "/tmp/new.json", "--native-wired-attested"]
      for (verb, ending) in [
        ("--lab-contact-loss", NativeExitEnding.disconnect),
        ("--lab-lease-expiry", NativeExitEnding.silence)
      ] {
        for rehearsal in [false, true] {
          #expect(
            try NativeLabCommand.parse([verb + (rehearsal ? "-rehearsal" : "")] + options)
              == .failure(
                external: 5, journal: "/tmp/new.json", ending: ending, rehearsal: rehearsal
              )
          )
        }
        #expect(
          NativeExitAuthorization.expectedTermination(reason: .exit, status: 1, ending: ending)
        )
        #expect(
          !NativeExitAuthorization.expectedTermination(reason: .exit, status: 0, ending: ending)
        )
        #expect(
          !NativeExitAuthorization.expectedTermination(
            reason: .uncaughtSignal, status: SIGKILL, ending: ending
          )
        )
      }
    }

    @Test func backendValidationIsItsOwnExplicitCommand() throws {
      let options = ["--external", "5", "--journal", "/tmp/v.json", "--native-wired-attested"]
      #expect(
        try NativeLabCommand.parse(["--lab-validate-backend"] + options)
          == .validateBackend(external: 5, journal: "/tmp/v.json")
      )
      // It cannot be reached without attesting a visible native external.
      #expect(throws: (any Error).self) {
        try NativeLabCommand.parse(["--lab-validate-backend"] + options.dropLast())
      }
    }

    @Test func terminationClassificationDoesNotConfuseSignalsWithNormalExit() {
      #expect(
        NativeExitAuthorization.expectedTermination(reason: .exit, status: 0, ending: .normal)
      )
      #expect(
        !NativeExitAuthorization.expectedTermination(
          reason: .uncaughtSignal, status: SIGKILL, ending: .normal
        )
      )
      for ending: NativeExitEnding in [.kill, .freeze] {
        #expect(
          NativeExitAuthorization.expectedTermination(
            reason: .uncaughtSignal, status: SIGKILL, ending: ending
          )
        )
        #expect(
          !NativeExitAuthorization.expectedTermination(reason: .exit, status: 0, ending: ending)
        )
        #expect(
          !NativeExitAuthorization.expectedTermination(
            reason: .uncaughtSignal, status: SIGTERM, ending: ending
          )
        )
      }
    }

    @Test func failureModesRequireExplicitSelection() throws {
      let options = ["--external", "5", "--journal", "/tmp/new.json", "--native-wired-attested"]
      #expect(
        try NativeLabCommand.parse(["--lab-exit-kill"] + options)
          == .failure(external: 5, journal: "/tmp/new.json", ending: .kill, rehearsal: false)
      )
      #expect(
        try NativeLabCommand.parse(["--lab-exit-freeze"] + options)
          == .failure(external: 5, journal: "/tmp/new.json", ending: .freeze, rehearsal: false)
      )
      #expect(
        try NativeLabCommand.parse(["--lab-freeze-rehearsal"] + options)
          == .failure(external: 5, journal: "/tmp/new.json", ending: .freeze, rehearsal: true)
      )
    }

    @Test func protocolPreservesSplitAndCoalescedSignals() throws {
      var buffer = NativeExitBuffer()
      buffer.receive(Data([NativeExitSignal.ready.rawValue]))
      #expect(try buffer.pop() == .ready)
      #expect(try buffer.pop() == nil)
      buffer.receive(Data([NativeExitSignal.arm.rawValue, NativeExitSignal.suppressed.rawValue]))
      #expect(try buffer.pop() == .arm)
      #expect(try buffer.pop() == .suppressed)
    }

    @Test func disconnectIsNotAnArmOrExitPermission() throws {
      var buffer = NativeExitBuffer()
      buffer.receive(Data())
      #expect(throws: NativeExitProtocolError.self) { try buffer.pop() }
      buffer.receive(Data([NativeExitSignal.arm.rawValue]))
      #expect(throws: NativeExitProtocolError.self) { try buffer.pop() }
    }

    @Test func unexpectedBytesAndExcessTrafficFailClosed() {
      var buffer = NativeExitBuffer()
      buffer.receive(Data([NativeExitSignal.arm.rawValue, 255]))
      #expect(throws: NativeExitProtocolError.self) { try buffer.pop() }
      var overflow = NativeExitBuffer()
      overflow.receive(Data(repeating: NativeExitSignal.ready.rawValue, count: 9))
      #expect(throws: NativeExitProtocolError.self) { try overflow.pop() }
    }

    @Test func queuedSignalSurvivesEOFButEOFDoesNotCreateAnother() throws {
      var buffer = NativeExitBuffer()
      buffer.receive(Data([NativeExitSignal.ready.rawValue]))
      buffer.receive(Data())
      #expect(try buffer.pop() == .ready)
      #expect(throws: NativeExitProtocolError.self) { try buffer.pop() }
    }

    @Test func recoveryAuthorityRequiresExactWitnessAndActualChild() throws {
      let target = PanelTarget(displayID: 1, displayUUID: "panel", bootID: "boot", loginID: 42)
      let journal = RecoveryJournal(target: target, scope: "app", ownerPID: 777)
      #expect(throws: Never.self) {
        try NativeExitAuthorization.validate(journal: journal, witnessed: target, childPID: 777)
      }
      for childPID: Int32 in [0, 1, 778] {
        #expect(throws: (any Error).self) {
          try NativeExitAuthorization.validate(
            journal: journal, witnessed: target, childPID: childPID
          )
        }
      }
      var wrongScope = journal
      wrongScope.scope = "session"
      #expect(throws: (any Error).self) {
        try NativeExitAuthorization.validate(journal: wrongScope, witnessed: target, childPID: 777)
      }
      let other = PanelTarget(
        displayID: 1, displayUUID: "different-panel", bootID: "boot", loginID: 42
      )
      #expect(throws: (any Error).self) {
        try NativeExitAuthorization.validate(journal: journal, witnessed: other, childPID: 777)
      }
    }

    @Test func rehearsalAndRealTestCannotBeConfusedByArgumentParsing() throws {
      let options = ["--external", "5", "--journal", "/tmp/new.json", "--native-wired-attested"]
      #expect(
        try NativeLabCommand.parse(["--lab-exit-rehearsal"] + options)
          == .supervisedExit(external: 5, journal: "/tmp/new.json", rehearsal: true)
      )
      #expect(
        try NativeLabCommand.parse(["--lab-exit-supervised"] + options)
          == .supervisedExit(external: 5, journal: "/tmp/new.json", rehearsal: false)
      )
      #expect(throws: (any Error).self) {
        try NativeLabCommand.parse(["--lab-exit-supervised"] + options.dropLast())
      }
    }
  }
#endif
