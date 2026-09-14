import Darwin
import Foundation

/// Production process roles. These are the only entry points a launch can reach.
nonisolated enum ProductionRole: Equatable {
  /// The menu-bar app a normal launch becomes. It decides, and starts guardians and workers.
  case app
  /// A child of the app that exists only while the laptop screen may be off.
  case guardian
  /// A one-shot process that makes exactly one display change for its parent, then exits.
  case worker
  /// Explicitly unprotected: the read-only interface with display control unavailable.
  case unprotected
}

nonisolated enum ProductionLaunchError: Error, CustomStringConvertible {
  case unpairedGuardian
  case unpairedWorker
  case conflictingRoles
  case unknownArgument(String)
  var description: String {
    switch self {
    case .unpairedGuardian:
      "The guardian role requires the private pipes inherited from its app."
    case .unpairedWorker:
      "The display worker role requires the private pipes inherited from its parent."
    case .conflictingRoles: "Only one production process role may be selected."
    case let .unknownArgument(argument): "Unrecognized argument: \(argument)."
    }
  }
}

nonisolated enum ProductionLaunch {
  static let guardianArgument = "--solodisplay-guardian"
  static let workerArgument = "--solodisplay-worker"
  static let unprotectedArgument = "--solodisplay-unprotected"

  /// A command-line claim is never the pairing evidence. Only actual inherited pipes on the
  /// standard descriptors let a process act as a child role.
  static func role(arguments: [String], pipedStandardStreams: Bool) throws -> ProductionRole {
    let roles = [guardianArgument, workerArgument, unprotectedArgument]
    for argument in arguments
      where argument.hasPrefix("--") && !roles.contains(argument) && argument != "--diagnostics" {
      throw ProductionLaunchError.unknownArgument(argument)
    }
    guard arguments.filter(roles.contains).count <= 1 else {
      throw ProductionLaunchError.conflictingRoles
    }
    if arguments.contains(guardianArgument) {
      guard pipedStandardStreams else { throw ProductionLaunchError.unpairedGuardian }
      return .guardian
    }
    if arguments.contains(workerArgument) {
      guard pipedStandardStreams else { throw ProductionLaunchError.unpairedWorker }
      return .worker
    }
    return arguments.contains(unprotectedArgument) ? .unprotected : .app
  }

  static func standardStreamsArePipes() -> Bool {
    ([0, 1] as [Int32]).allSatisfy { descriptor in
      var status = stat()
      return fstat(descriptor, &status) == 0 && (status.st_mode & S_IFMT) == S_IFIFO
    }
  }
}
