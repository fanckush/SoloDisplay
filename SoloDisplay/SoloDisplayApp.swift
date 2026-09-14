//
//  SoloDisplayApp.swift
//  SoloDisplay
//
//  Created by imad on 08.09.26.
//

import Darwin
import SwiftUI

@main
struct SoloDisplayApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  init() {
    // A display worker makes one call and exits. It never needs the menu or the app's run loop,
    // and starting them would only delay the change it was launched to make.
    let role = try? ProductionLaunch.role(
      arguments: Array(CommandLine.arguments.dropFirst()),
      pipedStandardStreams: ProductionLaunch.standardStreamsArePipes()
    )
    if role == .worker {
      exit(DisplayWorker.run())
    }
  }

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}
