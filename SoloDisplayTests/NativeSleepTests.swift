#if DEBUG
  import Testing
  @testable import SoloDisplay

  @MainActor struct NativeSleepTests {
    @Test func wakeWithoutSleepDoesNotCompleteExperiment() {
      var cycle = NativeSleepCycle()
      cycle.receive(.didWake)
      #expect(!cycle.completed)
      #expect(!cycle.sleeping)
      #expect(cycle.wakeCount == 0)
    }

    @Test func duplicatesDoNotManufactureMultipleCycles() {
      var cycle = NativeSleepCycle()
      cycle.receive(.willSleep)
      cycle.receive(.willSleep)
      #expect(cycle.sleeping)
      #expect(!cycle.completed)
      #expect(cycle.sleepCount == 1)
      cycle.receive(.didWake)
      cycle.receive(.didWake)
      #expect(cycle.completed)
      #expect(cycle.wakeCount == 1)
    }

    @Test func anotherSleepRevokesEarlierWakeReadiness() {
      var cycle = NativeSleepCycle()
      cycle.receive(.willSleep)
      cycle.receive(.didWake)
      #expect(cycle.completed)
      cycle.receive(.willSleep)
      #expect(!cycle.completed)
      #expect(cycle.sleeping)
      cycle.receive(.didWake)
      #expect(cycle.completed)
      #expect(cycle.sleepCount == 2 && cycle.wakeCount == 2)
    }

    @Test func sleepModesRequireExplicitRehearsalAndAttestation() throws {
      let options = ["--external", "5", "--journal", "/tmp/sleep.json", "--native-wired-attested"]
      for rehearsal in [false, true] {
        let suffix = rehearsal ? "-rehearsal" : ""
        #expect(
          try NativeLabCommand.parse(["--lab-sleep" + suffix] + options)
            == .failure(
              external: 5, journal: "/tmp/sleep.json", ending: .sleep, rehearsal: rehearsal
            )
        )
        #expect(
          try NativeLabCommand.parse(["--lab-sleep-writer" + suffix] + options)
            == .sleepWriter(external: 5, journal: "/tmp/sleep.json", rehearsal: rehearsal)
        )
      }
      #expect(throws: (any Error).self) {
        try NativeLabCommand.parse(["--lab-sleep"] + options.dropLast())
      }
    }
  }
#endif
