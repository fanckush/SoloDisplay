//
//  SoloDisplayApp.swift
//  SoloDisplay
//
//  Created by imad on 08.09.26.
//

import SwiftUI

@main
struct SoloDisplayApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}
