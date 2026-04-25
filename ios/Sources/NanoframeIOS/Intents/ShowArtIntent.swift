import AppIntents
import Foundation

// MARK: - App Intent

struct ShowArtOnFrameIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Art on Frame TV"
    static var description = IntentDescription(
        "Generate AI art from a description and display it on your Samsung Frame TV.",
        categoryName: "Frame TV"
    )

    // Runs silently in the background — Siri gets an immediate response
    // while generation and upload continue as a detached task.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Description", description: "What to show on the TV — be as specific as you like.")
    var artDescription: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tvIP = UserDefaults.standard.string(forKey: "tv_ip") ?? ""
        guard !tvIP.isEmpty else {
            return .result(dialog: "TV IP address isn't set yet. Open the Nanoframe app and add it in Settings first.")
        }

        let providerRaw = UserDefaults.standard.string(forKey: "image_provider") ?? ""
        let provider    = ImageProvider(rawValue: providerRaw) ?? .pollinations
        let apiKey: String
        switch provider {
        case .openAI:       apiKey = UserDefaults.standard.string(forKey: "openai_api_key") ?? ""
        case .nanoBanana:   apiKey = UserDefaults.standard.string(forKey: "nb_api_key") ?? ""
        case .pollinations: apiKey = ""
        }
        let savedToken = UserDefaults.standard.string(forKey: "samsung_tv_token") ?? ""
        let autoRevert    = UserDefaults.standard.bool(forKey: "auto_revert")
        let revertMinutes = UserDefaults.standard.integer(forKey: "revert_minutes")

        // Return immediately to Siri, do the work in the background.
        // This avoids Siri's ~10 s timeout on long-running intents.
        Task.detached {
            do {
                let svc      = DallEService()
                let (jpeg, _) = try await svc.generate(prompt: artDescription, apiKey: apiKey, provider: provider)
                let upscaled  = svc.upscaleTo4K(jpeg) ?? jpeg

                let client = SamsungArtClient(host: tvIP, savedToken: savedToken)
                try await client.checkReachable()
                try await client.connect()
                if !client.token.isEmpty {
                    UserDefaults.standard.set(client.token, forKey: "samsung_tv_token")
                }
                let contentId = try await client.uploadAndDisplay(upscaled)
                if !contentId.isEmpty {
                    var ids = UserDefaults.standard.stringArray(forKey: "nanoframe_content_ids") ?? []
                    ids.append(contentId)
                    UserDefaults.standard.set(ids, forKey: "nanoframe_content_ids")
                }

                if autoRevert && revertMinutes > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(revertMinutes * 60) * 1_000_000_000)
                    let revertClient = SamsungArtClient(host: tvIP, savedToken:
                        UserDefaults.standard.string(forKey: "samsung_tv_token") ?? "")
                    try? await revertClient.checkReachable()
                    try? await revertClient.connect()
                    let idsToDelete = UserDefaults.standard.bool(forKey: "delete_on_revert")
                        ? (UserDefaults.standard.stringArray(forKey: "nanoframe_content_ids") ?? [])
                        : []
                    try? await revertClient.revertToSamsungArt(deleteIds: idsToDelete)
                    revertClient.disconnect()
                }
            } catch {
                // Errors are silent in background mode — open the app to diagnose
                print("[Nanoframe] Siri intent failed: \(error)")
            }
        }

        return .result(dialog: "On it — \(artDescription) will appear on the Frame TV in about a minute.")
    }
}

// MARK: - Siri phrase registration

struct NanoframeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowArtOnFrameIntent(),
            phrases: [
                "Show art on the Frame TV with \(.applicationName)",
                "Put something on my TV with \(.applicationName)",
                "Change the Frame TV art with \(.applicationName)",
                "Display art on the Frame with \(.applicationName)"
            ],
            shortTitle: "Show Art on Frame TV",
            systemImageName: "tv"
        )
    }
}
