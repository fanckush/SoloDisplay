import Foundation
import SoloDisplayCore
import Synchronization

/// One monitor's Input Source answer, kept verbatim so a verdict can be argued with rather than
/// trusted. `reply` is nil when the monitor did not answer at all.
public struct InputSourceEvidence: Codable, Equatable, Sendable {
  public var controller: String
  /// The monitor this endpoint carries, live or remembered. An endpoint that has never been seen
  /// in CoreGraphics names no monitor anyone knows about, and its answer is not about one.
  public var target: PanelTarget?
  public var reply: DDCValue?

  public init(controller: String, target: PanelTarget? = nil, reply: DDCValue?) {
    self.controller = controller
    self.target = target
    self.reply = reply
  }

  public var shown: ShownSource {
    InputSourceClassifier.classify(self)
  }
}

/// The monitor behind each DDC endpoint, learned while the monitor is visible and kept while it
/// is not. A monitor that has been turned off leaves CoreGraphics entirely, so the correlation
/// cannot be made again while it is off: it has to be remembered from before.
public final class ControllerCorrelation: Sendable {
  private let known = Mutex<[String: PanelTarget]>([:])

  public init() {}

  /// From a reading already taken. The reading carries the endpoint names, so this costs nothing.
  public func learn(_ reading: PlatformReading) {
    guard let bootID = reading.bootID, let loginID = reading.loginID else { return }
    let targets = reading.displays.reduce(into: [String: PanelTarget]()) { found, display in
      guard !display.builtIn, let controller = reading.controllers[display.id],
            let uuid = display.uuid
      else { return }
      found[controller] = .init(
        displayID: display.id, displayUUID: uuid, bootID: bootID, loginID: loginID
      )
    }
    guard !targets.isEmpty else { return }
    // An endpoint is a port. The same port carrying a different monitor replaces what it carried.
    known.withLock { $0.merge(targets) { _, fresh in fresh } }
  }

  public func target(for controller: String) -> PanelTarget? {
    known.withLock { $0[controller] }
  }

  /// An endpoint that no longer enumerates is a monitor that has been unplugged, not one that is
  /// merely off, so what it carried is forgotten.
  public func forget(keeping live: Set<String>) {
    known.withLock { $0 = $0.filter { live.contains($0.key) } }
  }
}

public enum InputSourceClassifier {
  /// VCP 0x60 defines only the low byte: the input being displayed. The high byte is reserved,
  /// and the monitors that fill it put the input the asking host is wired to there. When both
  /// bytes say something and they differ, this Mac is plugged into one input while another is on
  /// screen. A zero in either byte is a monitor that fills nothing, not one that disagrees, so it
  /// stays unknown: zero is what a monitor following the standard returns, and reading it as
  /// disagreement would refuse every such monitor for ever. The maximum is never read. For a
  /// feature that is not continuous it means little, and one monitor is not a sample.
  public static func classify(_ evidence: InputSourceEvidence) -> ShownSource {
    guard let reply = evidence.reply else { return .unknown }
    let displayed = UInt8(reply.current & 0xFF)
    let asking = UInt8(reply.current >> 8)
    guard displayed != 0, asking != 0 else { return .unknown }
    return displayed == asking ? .thisMac : .otherMachine
  }

  /// The verdict across every monitor asked at once. A monitor that says nothing is not evidence:
  /// it can neither raise a refusal nor lift one. One monitor showing this Mac settles it, even
  /// beside another showing something else, because the Mac is visible either way.
  ///
  /// Endpoints with no correlated monitor are left out. Asking over IOKit reaches more endpoints
  /// than CoreGraphics ever listed, and whether the laptop screen may be off must not widen as a
  /// side effect of reaching further.
  public static func showingThisMac(_ evidence: [InputSourceEvidence]) -> Fact {
    let known = evidence.filter { $0.target != nil }
    if known.contains(where: { $0.shown == .thisMac }) {
      return .yes
    }
    if known.contains(where: { $0.shown == .otherMachine }) {
      return .no
    }
    return .unknown
  }

  /// What each monitor said, one answer per endpoint. The aggregate above decides the laptop
  /// screen; these decide what may be done to the monitors themselves.
  public static func perMonitor(_ evidence: [InputSourceEvidence]) -> [MonitorAnswer] {
    evidence.map { .init(controller: $0.controller, target: $0.target, shown: $0.shown) }
  }
}

/// Asks each answerable monitor, on that monitor's own DDC lane so the exchange never interleaves
/// with brightness traffic on the same wire.
public struct LiveInputSourceObserver: InputSourceObserving {
  private let correlation: ControllerCorrelation

  public init(correlation: ControllerCorrelation = .init()) {
    self.correlation = correlation
  }

  /// Every reading teaches which endpoint carries which monitor. Called by the coordinator, on
  /// the main actor, so it reads the reading it is given and never touches IOKit itself.
  public func learn(_ reading: PlatformReading) {
    correlation.learn(reading)
  }

  /// Asked over IOKit rather than CoreGraphics: a monitor that is switched away, or one this app
  /// has turned off, keeps its DDC service but leaves the display list.
  public func read() -> [InputSourceEvidence] {
    guard IOAVServiceDDC.available else { return [] }
    let live = IOAVServiceDDC.externalControllers().sorted()
    // An endpoint that no longer enumerates is a monitor that has gone, not one that is off.
    correlation.forget(keeping: Set(live))
    return live.map { controller in
      // Two attempts, not the default three: the controller confirms an answer that would change
      // something by asking again, which covers a transient better than another retry here does.
      .init(
        controller: controller, target: correlation.target(for: controller),
        reply: DDCLanes.lane(for: controller)
          .perform { try $0.get(code: DDCPacket.inputSource, attempts: 2) }
      )
    }
  }
}
