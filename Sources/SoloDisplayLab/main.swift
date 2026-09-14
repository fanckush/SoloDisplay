import Foundation
import SoloDisplayPlatform

let usage = """
solodisplay-lab observe
    Read-only display and capability report. This is the default command.
    It never changes a display.
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

do {
  let args = Array(CommandLine.arguments.dropFirst())
  switch args.first ?? "observe" {
  case "observe":
    guard args.count <= 1 else { throw LabError.message("observe takes no options.") }
    try emit(DisplayObserver.read())
  case "help", "--help", "-h":
    print(usage)
  default:
    throw LabError.message(usage)
  }
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
