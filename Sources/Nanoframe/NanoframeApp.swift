import SwiftUI
import AppKit

/// Starts the LAN trigger server from a true app-lifecycle hook, not from a SwiftUI
/// view's `.onAppear`. The server is what Lango's frame_tv tool calls, and it must come
/// up on every launch regardless of whether the main window ever actually appears
/// (window-state restoration can otherwise leave the app running with no open window
/// and, since the server used to start from ContentView.onAppear, no listener either).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let vm = AppViewModel()
    private var server: RemoteTriggerServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let s = RemoteTriggerServer { [weak vm] prompt in
            guard let vm else { return }
            Task { await vm.generateAndSend(prompt: prompt) }
        }
        s.start()
        server = s
    }
}

@main
struct NanoframeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Nanoframe", id: "main") {
            ContentView(vm: appDelegate.vm)
        }
        .defaultSize(width: 1160, height: 720)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
