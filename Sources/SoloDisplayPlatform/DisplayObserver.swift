import ColorSync
import CoreGraphics
import Foundation
import IOKit
import Security
import SoloDisplayCore

public struct DisplayReading: Codable, Equatable, Sendable {
  public var id: UInt32
  public var uuid: String?
  public var uuidResolvedID: UInt32?
  public var builtIn: Bool
  public var active: Bool
  public var online: Bool
  public var asleep: Bool
  public var mirrored: Bool
  public var mirrorSourceID: UInt32?
  public var width: Int
  public var height: Int
  public var originX: Int
  public var originY: Int
  public var modeAvailable: Bool
  /// CoreGraphics does not by itself prove a physical, native wired transport.
  public var transport: String = "unclassified"

  public var usableExternalCandidate: Bool {
    !builtIn && active && online && !asleep && !mirrored
      && modeAvailable && width > 0 && height > 0
  }
}

public struct PlatformReading: Codable, Sendable {
  public var schemaVersion = 1
  public var osVersion: String
  public var monotonicMilliseconds: Int64
  public var enumerationError: Int32?
  public var displays: [DisplayReading]
  public var lid: Lid
  public var bootID: String?
  public var loginID: UInt32?
  public var foregroundSession: Fact
  public var privateSymbol: String?
  public var backendValidated = false
  /// Kept verbatim so a transport decision can be inspected rather than taken on trust.
  public var transportEvidence: [TransportEvidence] = []
  public var limitations: [String]

  public var mirroringDetected: Bool {
    displays.contains(where: \.mirrored)
  }

  public var internalTarget: PanelTarget? {
    let internalDisplays = displays.filter(\.builtIn)
    guard internalDisplays.count == 1, let display = internalDisplays.first,
          let uuid = display.uuid, let bootID, let loginID
    else { return nil }
    return .init(displayID: display.id, displayUUID: uuid, bootID: bootID, loginID: loginID)
  }
}

public enum DisplayObserver {
  /// `validation` is supplied by the coordinator after loading a recorded round trip. Callers
  /// that omit it get an explicitly unvalidated backend, which inhibits disabling.
  public static func read(validation: BackendValidation? = nil) -> PlatformReading {
    let start = Int64(ProcessInfo.processInfo.systemUptime * 1000)
    var count: UInt32 = 0
    let countResult = CGGetOnlineDisplayList(0, nil, &count)
    // Headroom avoids truncation when a display arrives between the two calls.
    var ids = [CGDirectDisplayID](repeating: 0, count: max(Int(count) + 8, 16))
    let result = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
    let error = countResult != .success ? countResult : result
    let evidence =
      error == .success
        ? DisplayTransportClassifier.evidence(
          for: ids.prefix(Int(count)).map { ($0, CGDisplayIsBuiltin($0) != 0) }
        )
        : []
    let displays: [DisplayReading] =
      error == .success
        ? ids.prefix(Int(count)).map { id in
          let bounds = CGDisplayBounds(id)
          let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
          return DisplayReading(
            id: id, uuid: uuid.map { CFUUIDCreateString(nil, $0) as String },
            uuidResolvedID: uuid.map { CGDisplayGetDisplayIDFromUUID($0) },
            builtIn: CGDisplayIsBuiltin(id) != 0, active: CGDisplayIsActive(id) != 0,
            online: CGDisplayIsOnline(id) != 0, asleep: CGDisplayIsAsleep(id) != 0,
            mirrored: CGDisplayIsInMirrorSet(id) != 0,
            mirrorSourceID: CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay
              ? nil : CGDisplayMirrorsDisplay(id),
            width: Int(bounds.width), height: Int(bounds.height), originX: Int(bounds.origin.x),
            originY: Int(bounds.origin.y),
            modeAvailable: CGDisplayCopyDisplayMode(id) != nil,
            transport: (evidence.first { $0.displayID == id }?.transport ?? .unclassified).rawValue
          )
        } : []

    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    var lid: Lid = .unknown
    var bootID: String?
    if root != 0 {
      defer { IOObjectRelease(root) }
      if let value = IORegistryEntryCreateCFProperty(
        root, "AppleClamshellState" as CFString, nil, 0
      )?.takeRetainedValue() {
        if CFGetTypeID(value) == CFBooleanGetTypeID(), let isClosed = value as? Bool {
          lid = isClosed ? .closed : .open
        }
      } else {
        // This is absence on a successfully queried root, not a failed IOKit lookup.
        lid = .absent
      }
      bootID =
        IORegistryEntryCreateCFProperty(root, "BootSessionUUID" as CFString, nil, 0)?
          .takeRetainedValue() as? String
    }
    var loginID: SecuritySessionId = 0
    var attributes: SessionAttributeBits = []
    let sessionResult = SessionGetInfo(callerSecuritySession, &loginID, &attributes)
    var foreground: Fact = .unknown
    if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
       let console = session[kCGSessionOnConsoleKey as String] as? Bool,
       let loggedIn = session[kCGSessionLoginDoneKey as String] as? Bool {
      foreground = console && loggedIn ? .yes : .no
    }
    let api = PrivateDisplayAPI()
    var limitations = [
      "Native transport classification is not validated. Candidates are not proof of a usable physical monitor.",
      "Lab recovery has been exercised on one setup; production recovery integration is not validated.",
      "This observer performs no display configuration changes."
    ]
    if error != .success || displays.isEmpty {
      limitations.append(
        "No reliable display inventory is available in this execution context. This does not prove that no displays exist."
      )
    }
    if displays.contains(where: \.mirrored) {
      limitations.insert(
        "Mirroring detected. Mirroring plus a dimmed built-in screen is a normal incoming setup. Preserving its arrangement through suppression and restoration still needs a separate hardware experiment; SoloDisplay will not silently convert it to extended mode.",
        at: 0
      )
    }
    if bootID == nil || sessionResult != errSecSuccess {
      limitations.append(
        "Boot or GUI session identity is unavailable; recovery target creation is disabled."
      )
    }
    return .init(
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      monotonicMilliseconds: start, enumerationError: error == .success ? nil : error.rawValue,
      displays: displays, lid: lid, bootID: bootID,
      loginID: sessionResult == errSecSuccess ? loginID : nil,
      foregroundSession: foreground, privateSymbol: api.symbolName,
      backendValidated: validation?.covers(
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        hardwareModel: BackendValidation.hardwareModel(), symbolName: api.symbolName
      ) ?? false,
      transportEvidence: evidence, limitations: limitations
    )
  }
}
