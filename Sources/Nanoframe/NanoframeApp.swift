import SwiftUI
import AppKit

@main
struct NanoframeApp: App {
    var body: some Scene {
        Window("Nanoframe", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1160, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
