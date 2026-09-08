//
//  LidlessApp.swift
//  Lidless
//
//  Created by imad on 08.09.26.
//

import SwiftUI

@main
struct LidlessApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}
