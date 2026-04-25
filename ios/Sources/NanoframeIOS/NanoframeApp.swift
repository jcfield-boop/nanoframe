import SwiftUI
import AppIntents
import BackgroundTasks

@main
struct NanoframeApp: App {
    @StateObject private var vm = AppViewModel()

    init() {
        // Register the background revert task — must happen before app finishes launching.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.nanoframe.revert",
            using: nil
        ) { task in
            handleRevertTask(task as! BGProcessingTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
        }
    }
}

// MARK: - Background revert handler

private func handleRevertTask(_ task: BGProcessingTask) {
    task.expirationHandler = { task.setTaskCompleted(success: false) }

    Task {
        let tvIP = UserDefaults.standard.string(forKey: "tv_ip") ?? ""
        guard !tvIP.isEmpty else { task.setTaskCompleted(success: false); return }

        let client = SamsungArtClient(
            host: tvIP,
            savedToken: UserDefaults.standard.string(forKey: "samsung_tv_token") ?? ""
        )
        do {
            try await client.checkReachable()
            try await client.connect()
            if !client.token.isEmpty {
                UserDefaults.standard.set(client.token, forKey: "samsung_tv_token")
            }
            let idsToDelete = UserDefaults.standard.bool(forKey: "delete_on_revert")
                ? (UserDefaults.standard.stringArray(forKey: "nanoframe_content_ids") ?? [])
                : []
            try await client.revertToSamsungArt(deleteIds: idsToDelete)
            client.disconnect()
            if UserDefaults.standard.bool(forKey: "delete_on_revert") {
                UserDefaults.standard.set([], forKey: "nanoframe_content_ids")
            }
            task.setTaskCompleted(success: true)
        } catch {
            client.disconnect()
            task.setTaskCompleted(success: false)
        }
    }
}
