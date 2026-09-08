#if DEBUG
  import Foundation
  import LidlessCore
  import LidlessPlatform
  import Testing

  @testable import Lidless

  @MainActor
  struct NativeRecoveryLabTests {
    @Test func ordinaryLaunchNeverSelectsAHardwareExperiment() throws {
      #expect(try NativeLabCommand.parse([]) == nil)
      #expect(try NativeLabCommand.parse(["--diagnostics"]) == nil)
      #expect(try NativeLabCommand.parse(["--lab-check"]) == .check)
    }

    @Test func handoffRequiresAnExactExplicitAttestation() throws {
      let args = [
        "--lab-handoff", "--external", "5", "--journal", "/tmp/example.recovery.json",
        "--native-wired-attested",
      ]
      #expect(
        try NativeLabCommand.parse(args)
          == .handoff(external: 5, journal: "/tmp/example.recovery.json"))
      #expect(throws: (any Error).self) { try NativeLabCommand.parse(Array(args.dropLast())) }
      #expect(throws: (any Error).self) { try NativeLabCommand.parse(args + ["--external", "6"]) }
      #expect(throws: (any Error).self) { try NativeLabCommand.parse(args + ["--ending", "exit"]) }
    }

    @Test func malformedOrRelativeTargetsAreRefused() {
      for external in ["0", "-1", "4294967296", "display"] {
        #expect(throws: (any Error).self) {
          try NativeLabCommand.parse([
            "--lab-handoff", "--external", external, "--journal", "/tmp/example.json",
            "--native-wired-attested",
          ])
        }
      }
      #expect(throws: (any Error).self) {
        try NativeLabCommand.parse(["--lab-restore-child", "--journal", "relative.json"])
      }
      #expect(throws: (any Error).self) {
        try NativeLabCommand.parse(["--lab-check", "--native-wired-attested"])
      }
      #expect(throws: (any Error).self) { try NativeLabCommand.parse(["--lab-crash"]) }
    }

    @Test func childCommandCannotSelectASeparateTarget() throws {
      #expect(
        try NativeLabCommand.parse(["--lab-restore-child", "--journal", "/tmp/example.json"])
          == .restoreChild(journal: "/tmp/example.json"))
      #expect(throws: (any Error).self) {
        try NativeLabCommand.parse([
          "--lab-restore-child", "--journal", "/tmp/example.json", "--external", "5",
        ])
      }
    }

    @Test func childSuccessNeverAuthorizesADuplicateEnable() {
      for active in [false, true] {
        #expect(
          NativeLabHandoffDecision.decide(child: .exited(0), panelActive: active) == .verifyOnly)
        #expect(
          NativeLabHandoffDecision.decide(child: .terminationUnverified, panelActive: active)
            == .forbidSecondWriter)
      }
    }

    @Test func fallbackRequiresAQuiescentFailedChildAndMissingActivePanel() {
      for outcome: NativeLabChildOutcome in [.exited(1), .exited(-1), .notStarted] {
        #expect(
          NativeLabHandoffDecision.decide(child: outcome, panelActive: false) == .restoreInOwner)
        #expect(
          NativeLabHandoffDecision.decide(child: outcome, panelActive: true) == .reportChildFailure)
      }
    }

    @Test func baselineRequiresReliableExtendedOpenLidEvidence() throws {
      let good = try fixture()
      #expect(try NativeLabSafety.baseline(good, external: 5).displayID == 1)
      var bad = good
      bad.displays[0].mirrored = true
      #expect(throws: (any Error).self) { try NativeLabSafety.baseline(bad, external: 5) }
      bad = good
      bad.enumerationError = 1000
      #expect(throws: (any Error).self) { try NativeLabSafety.baseline(bad, external: 5) }
      bad = good
      bad.displays = []
      #expect(throws: (any Error).self) { try NativeLabSafety.baseline(bad, external: 5) }
      bad = good
      bad.lid = .closed
      #expect(throws: (any Error).self) { try NativeLabSafety.baseline(bad, external: 5) }
      bad = good
      bad.foregroundSession = .unknown
      #expect(throws: (any Error).self) { try NativeLabSafety.baseline(bad, external: 5) }
      #expect(throws: (any Error).self) { try NativeLabSafety.baseline(good, external: 1) }
    }

    @Test func recoveryRejectsChangedBootAndContradictoryTarget() throws {
      let good = try fixture()
      let target = try NativeLabSafety.baseline(good, external: 5)
      let journal = RecoveryJournal(target: target, scope: "app", ownerPID: 999)
      var absent = good
      absent.displays.removeFirst()
      #expect(throws: Never.self) { try NativeLabSafety.ownedContext(absent, journal: journal) }
      var bad = good
      bad.bootID = "different-boot"
      #expect(throws: (any Error).self) { try NativeLabSafety.ownedContext(bad, journal: journal) }
      bad = good
      bad.displays[0].uuid = "replacement-panel"
      #expect(throws: (any Error).self) { try NativeLabSafety.ownedContext(bad, journal: journal) }
      bad = good
      bad.lid = .closed
      #expect(throws: (any Error).self) { try NativeLabSafety.ownedContext(bad, journal: journal) }
    }

    private func fixture() throws -> PlatformReading {
      let data = Data(
        #"""
        {"schemaVersion":1,"osVersion":"synthetic","monotonicMilliseconds":100,
         "lid":"open","bootID":"synthetic-boot","loginID":42,"foregroundSession":"yes",
         "backendValidated":false,"limitations":[],"displays":[
          {"id":1,"uuid":"synthetic-panel","uuidResolvedID":1,"builtIn":true,"active":true,
           "online":true,"asleep":false,"mirrored":false,"width":1512,"height":982,
           "originX":0,"originY":0,"modeAvailable":true,"transport":"unclassified"},
          {"id":5,"uuid":"synthetic-external","uuidResolvedID":5,"builtIn":false,"active":true,
           "online":true,"asleep":false,"mirrored":false,"width":1920,"height":1080,
           "originX":1512,"originY":0,"modeAvailable":true,"transport":"unclassified"}
         ]}
        """#.utf8)
      return try JSONDecoder().decode(PlatformReading.self, from: data)
    }
  }
#endif
