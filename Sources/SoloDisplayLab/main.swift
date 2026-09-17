import CoreGraphics
import Foundation
import SoloDisplayPlatform

let usage = """
solodisplay-lab observe
    Read-only display and capability report. This is the default command.
    It never changes a display.
solodisplay-lab ddc list
    Lists external displays with the display controller that carries their DDC service.
solodisplay-lab ddc get [displayID]
    Reads the brightness of an external display over DDC.
solodisplay-lab ddc set <value> [displayID]
    Sets the brightness of an external display over DDC.
"""

enum LabError: Error, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self {
    case let .message(text): text
    }
  }
}

func emit(_ value: some Encodable) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(value)
  print(String(bytes: data, encoding: .utf8) ?? "")
}

func runDDC(_ args: [String]) throws {
  guard IOAVServiceDDC.available else { throw DDCError.unavailable }
  var ids = [CGDirectDisplayID](repeating: 0, count: 16)
  var count: UInt32 = 0
  CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
  let externals = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
  let controllers = IOAVServiceDDC.controllers(forDisplays: Array(externals))
  let services = Set(IOAVServiceDDC.externalControllers())
  func controller(at position: Int) throws -> String {
    if args.count > position {
      guard let id = UInt32(args[position]), let name = controllers[id] else {
        throw LabError.message("No DDC display with ID \(args[position]).")
      }
      return name
    }
    let usable = controllers.values.filter(services.contains)
    guard usable.count == 1 else {
      throw LabError.message("Name a display ID. \(usable.count) DDC displays are connected.")
    }
    return usable[0]
  }
  switch args.first {
  case "list":
    for id in externals {
      let name = controllers[id] ?? "unmatched"
      let ddc = services.contains(name) ? "DDC service" : "no DDC service"
      print("display \(id): \(name), \(ddc)")
    }
  case "get":
    try emit(IOAVServiceDDC.channel(controller: controller(at: 1)).get(code: DDCPacket.brightness))
  case "set":
    guard args.count >= 2, let value = UInt16(args[1]) else { throw LabError.message(usage) }
    try IOAVServiceDDC.channel(controller: controller(at: 2))
      .set(code: DDCPacket.brightness, value: value)
  default:
    throw LabError.message(usage)
  }
}

do {
  let args = Array(CommandLine.arguments.dropFirst())
  switch args.first ?? "observe" {
  case "observe":
    guard args.count <= 1 else { throw LabError.message("observe takes no options.") }
    try emit(DisplayObserver.read())
  case "ddc":
    try runDDC(Array(args.dropFirst()))
  case "help", "--help", "-h":
    print(usage)
  default:
    throw LabError.message(usage)
  }
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
