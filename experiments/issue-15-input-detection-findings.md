# Issue #15: v0.6 input detection and external suppression

Investigated 2026-09-24 against the exact `v0.6.0` sources in an isolated temporary
directory. Production code was not changed and no display operations were run.

## Finding and confidence

The strongest suspect is the input-awareness and external-suppression feature
introduced in v0.6. It applies a behavior measured on one Dell monitor to every
monitor with a correlated DDC endpoint. Synthetic tests demonstrate that this can
request external off/on/off transitions. A separate failing test establishes that
unanswered DDC polls defeat the intended silence recovery timeout.

This does **not** establish the Samsung's actual reply or reproduce the complete
both-screens-black incident. The simulated laptop panel stays enabled throughout.
The controller and display worker both try to preserve another usable screen;
why the reporter's laptop screen also remains black needs incident evidence.

## Release boundary

The [issue](https://github.com/fanckush/SoloDisplay/issues/15) names an M5 MacBook Air
and Samsung C27FG7x over HDMI. Its title mentions v0.7, while its body dates the
regression to v0.6. At investigation time the comments contained no diagnostic
attachment, despite the reporter's message saying reports were sent.

Only three commits separate v0.5.1 from v0.6.0:

| Commit | Change | Relevance |
| --- | --- | --- |
| `fb3bd63` | External monitor input awareness | Introduces the reserved-byte interpretation and polling. |
| `e77cab4` | Disable external monitor when input is set to another device | Gives that interpretation authority to disable the external monitor. |
| `a15224e` | Recovery changes for #9 | Changes internal-panel recovery and settling; remains an alternative contributor. |

v0.5.0 to v0.5.1 only added AppleCLCD2 transport support. Brightness DDC existed in
v0.5, but the input-source polling and external-disable feature did not.

## Code paths

`Sources/SoloDisplayPlatform/InputSource.swift:68` interprets VCP 0x60's low byte
as the selected input and its nonzero high byte as the input connected to this
Mac. Unequal bytes become `.otherMachine`. There is no monitor-model or protocol
profile check. `docs/hardware-findings.md` explicitly records that the high-byte
meaning is outside the standard and was measured on a Dell U3223QE over USB-C.
Two readings confirm repetition, not the meaning of this reserved byte.

`Sources/SoloDisplayCore/Controller.swift:293` can then select the monitor for
suppression. This path operates in all three modes, including All Monitors.
`monitorToRestore` accepts one contrary `.thisMac` answer, whereas the standing
`.otherMachine` verdict requires two contrary readings to change. A subsequent
disagreement can therefore make the monitor eligible for suppression again after
the 30-second settle floor.

There is also a definite recovery bug at `Controller.swift:172`: `lastAnswered`
is refreshed even when `shown == .unknown`, including an enumerated endpoint
whose DDC exchange returned no reply. The five-minute silence check at line 288
therefore never expires while these unsuccessful polls keep completing. The
existing timeout test sends no intervening polls and misses this case.

## Isolated reproduction

The companion `issue-15-regression-tests.swift` uses the real classifier and
controller, with synthetic observations and replies. `0x0111` and `0x1111` are
invented examples, **not Samsung captures**.

- Two `0x0111` replies authorize an external disable in automatic,
  automaticPaused, and manual modes.
- Changing these synthetic replies requests external disable, enable, and disable
  again, with the record and guardian prerequisites completed at each step.
- After suppression, nil replies every ten seconds for 400 seconds prevent any
  restore request. The test expecting silence recovery fails on v0.6.0.
- All 21 existing tests selected from `InputSourceTests`,
  `MonitorSuppressionTests`, and `GuardianKnowledgeTests` pass. The two new
  characterization tests pass; the new recovery expectation is the sole failure.

Reproduce from the repository root without changing its checkout:

```sh
issue15_dir=$(mktemp -d /private/tmp/solodisplay-issue15.XXXXXX)
git archive v0.6.0 Package.swift Sources Tests | tar -x -C "$issue15_dir"
cp experiments/issue-15-regression-tests.swift \
  "$issue15_dir/Tests/SoloDisplayPlatformTests/Issue15InvestigationTests.swift"
cd "$issue15_dir"
CLANG_MODULE_CACHE_PATH="$issue15_dir/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$issue15_dir/module-cache" \
swift test --disable-sandbox \
  --filter 'InputSourceTests|MonitorSuppressionTests|Issue15InvestigationTests'
```

The command is expected to exit unsuccessfully for the recovery assertion.

## Evidence needed to resolve #15

The current diagnostic export can show `monitorSuppressing` and
`monitorRestoring` events and the final `inputSources` verdict. A
`monitorSuppressing` event with `workerAction: disable` identifies an external
disable dispatch; record-writing events use the same name without that action.
Worker outcomes and observations are needed to determine whether it took effect.
Raw VCP replies and per-monitor verdict history are not currently exported.

The most discriminating next comparison is v0.6 with input polling and external
suppression bypassed, retaining the #9 recovery changes. If that resolves the
incident on the reporter's hardware, separate passive input reads from suppression
to distinguish DDC transport effects from classification-driven writes. A raw
VCP 0x60 capture while the Samsung visibly shows this Mac would directly test the
reserved-byte hypothesis. Any separate DDC probe should run with SoloDisplay quit
to avoid two processes competing on the same bus.

The likely correction is to require established monitor-specific semantics or an
explicitly calibrated host input before treating a reserved byte as authority to
disable a display. Independently, unanswered polls must not refresh the last
meaningful-answer time. Neither change alone is yet a verified hardware fix for
the complete incident.
