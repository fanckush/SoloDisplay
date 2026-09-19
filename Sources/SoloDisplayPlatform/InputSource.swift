import Foundation
import SoloDisplayCore

/// What one monitor is showing. Only `otherMachine` ever changes what SoloDisplay does, and only
/// by refusing. `unknown` is the default and is never read as a quiet yes.
public enum ShownSource: String, Codable, Equatable, Sendable {
  case thisMac, otherMachine, unknown
}

/// One monitor's Input Source answer, kept verbatim so a verdict can be argued with rather than
/// trusted. `reply` is nil when the monitor did not answer at all.
public struct InputSourceEvidence: Codable, Equatable, Sendable {
  public var controller: String
  public var reply: DDCValue?

  public init(controller: String, reply: DDCValue?) {
    self.controller = controller
    self.reply = reply
  }

  public var shown: ShownSource {
    InputSourceClassifier.classify(self)
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
  public static func showingThisMac(_ evidence: [InputSourceEvidence]) -> Fact {
    if evidence.contains(where: { $0.shown == .thisMac }) {
      return .yes
    }
    if evidence.contains(where: { $0.shown == .otherMachine }) {
      return .no
    }
    return .unknown
  }
}

/// Asks each answerable monitor, on that monitor's own DDC lane so the exchange never interleaves
/// with brightness traffic on the same wire.
public struct LiveInputSourceObserver: InputSourceObserving {
  public init() {}

  public func read() -> [InputSourceEvidence] {
    guard IOAVServiceDDC.available else { return [] }
    return IOAVServiceDDC.answerableControllers().values.sorted().map { controller in
      // Two attempts, not the default three: the controller confirms an answer that would change
      // something by asking again, which covers a transient better than another retry here does.
      .init(
        controller: controller,
        reply: DDCLanes.lane(for: controller)
          .perform { try $0.get(code: DDCPacket.inputSource, attempts: 2) }
      )
    }
  }
}
