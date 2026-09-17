import AppKit
import ObjectiveC

/// The system brightness indicator, shown on the monitor being changed. It comes from the
/// private OSD framework; when that is missing or changed, nothing is shown.
@MainActor
enum BrightnessIndicator {
  private typealias Show = @convention(c) (
    AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool
  ) -> Void

  private static let brightnessImage: Int64 = 1
  private static let priority: UInt32 = 0x1F4
  private static let fadeAfter: UInt32 = 1000
  private static let selector = NSSelectorFromString(
    "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"
  )

  private static let call: (manager: AnyObject, show: Show)? = {
    guard dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_LAZY) != nil,
          let type = NSClassFromString("OSDManager") as? NSObject.Type,
          type.responds(to: NSSelectorFromString("sharedManager")),
          let manager = type.perform(NSSelectorFromString("sharedManager"))?
          .takeUnretainedValue(),
          manager.responds(to: selector),
          let implementation = object_getClass(manager)
          .flatMap({ class_getMethodImplementation($0, selector) })
    else { return nil }
    return (manager, unsafeBitCast(implementation, to: Show.self))
  }()

  static func show(filled: Int, of total: Int, on displayID: CGDirectDisplayID) {
    guard let call else { return }
    call.show(
      call.manager, selector, brightnessImage, displayID, priority, fadeAfter,
      UInt32(max(0, filled)), UInt32(max(0, total)), false
    )
  }
}
