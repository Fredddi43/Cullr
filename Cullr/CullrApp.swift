// VideoCullerApp.swift

import SwiftUI

@main
struct Cullr: App {
  @StateObject private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .frame(minWidth: 1700, minHeight: 800)
        .environmentObject(appState)
    }
  }
}
