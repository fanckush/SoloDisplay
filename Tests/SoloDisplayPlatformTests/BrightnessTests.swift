import Dispatch
import Synchronization
import Testing
@testable import SoloDisplayPlatform

/// Builds a system-defined event's data1 the way the HID system does.
private func data1(keyType: Int, state: Int, repeating: Bool = false) -> Int {
  keyType << 16 | state << 8 | (repeating ? 1 : 0)
}

struct BrightnessKeyTests {
  @Test func brightnessKeysDecodeWithTheirState() {
    let up = BrightnessKey.decode(subtype: 8, data1: data1(keyType: 2, state: 0x0A))
    #expect(up?.key == .up && up?.pressed == true)
    let release = BrightnessKey.decode(subtype: 8, data1: data1(keyType: 3, state: 0x0B))
    #expect(release?.key == .down && release?.pressed == false)
    let held = BrightnessKey.decode(
      subtype: 8, data1: data1(keyType: 2, state: 0x0A, repeating: true)
    )
    #expect(held?.pressed == true)
  }

  @Test func otherKeysAndEventsAreLeftAlone() {
    // Volume up, and a brightness type under another subtype.
    #expect(BrightnessKey.decode(subtype: 8, data1: data1(keyType: 0, state: 0x0A)) == nil)
    #expect(BrightnessKey.decode(subtype: 7, data1: data1(keyType: 2, state: 0x0A)) == nil)
    #expect(BrightnessKey.from(keyCode: 144) == .up)
    #expect(BrightnessKey.from(keyCode: 145) == .down)
    #expect(BrightnessKey.from(keyCode: 0) == nil)
  }
}

struct BrightnessLevelTests {
  @Test func stepsAreSixteenthsOfTheRange() {
    let level = BrightnessLevel(value: 50, maximum: 100)
    #expect(level.stepped(.up).value == 56)
    #expect(level.stepped(.down).value == 44)
  }

  @Test func aValueBetweenStepsSnapsBeforeMoving() {
    // 40 is nearest step 6 (37.5), so one step up lands on step 7.
    #expect(BrightnessLevel(value: 40, maximum: 100).stepped(.up).value == 44)
  }

  @Test func theEndsHold() {
    #expect(BrightnessLevel(value: 100, maximum: 100).stepped(.up).value == 100)
    #expect(BrightnessLevel(value: 0, maximum: 100).stepped(.down).value == 0)
    #expect(BrightnessLevel(value: 3, maximum: 100).stepped(.down).value == 0)
    // A display that reports no range is never moved.
    #expect(BrightnessLevel(value: 0, maximum: 0).stepped(.up).value == 0)
  }

  @Test func filledStepsFollowTheSixteenStepScale() {
    #expect(BrightnessLevel(value: 50, maximum: 100).filledSteps == 8)
    #expect(BrightnessLevel(value: 100, maximum: 100).filledSteps == 16)
    #expect(BrightnessLevel(value: 0, maximum: 100).filledSteps == 0)
  }

  @Test func fractionIsBounded() {
    #expect(BrightnessLevel(value: 25, maximum: 100).fraction == 0.25)
    #expect(BrightnessLevel(value: 120, maximum: 100).fraction == 1)
    #expect(BrightnessLevel(value: 5, maximum: 0).fraction == 0)
  }
}

struct LatestValueWriterTests {
  @Test func valuesSubmittedDuringAStalledWriteCollapseToTheNewest() async {
    let gate = DispatchSemaphore(value: 0)
    let written = Mutex<[Int]>([])
    let queue = DispatchQueue(label: "test.writer")
    let writer = LatestValueWriter<Int>(queue: queue) { value in
      written.withLock { $0.append(value) }
      if value == 1 {
        gate.wait()
      }
    }
    writer.submit(1)
    // Wait until the first write is under way, then pile up behind it.
    while written.withLock({ $0.isEmpty }) {
      await Task.yield()
    }
    for value in 2 ... 5 {
      writer.submit(value)
    }
    gate.signal()
    // The drain loop runs as one queue item, so this hop waits for it to finish.
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume() }
    }
    #expect(written.withLock { $0 } == [1, 5])
  }

  @Test func aWriterStartsAgainAfterGoingIdle() async {
    let written = Mutex<[Int]>([])
    let queue = DispatchQueue(label: "test.writer.idle")
    let writer = LatestValueWriter<Int>(queue: queue) { value in
      written.withLock { $0.append(value) }
    }
    writer.submit(1)
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    writer.submit(2)
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    #expect(written.withLock { $0 } == [1, 2])
  }
}
