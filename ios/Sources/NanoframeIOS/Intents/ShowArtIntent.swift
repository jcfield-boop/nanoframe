import AppIntents
import Foundation

// MARK: - App Intent

/// Exposed to Siri and the Shortcuts app.
/// Siri phrases (after adding to Shortcuts):
///   "Show a sunset on the Frame TV using Nanoframe"
///   "Put puppies playing on my TV using Nanoframe"
///
/// With AppShortcutsProvider below, users can also say:
///   "Show [art description] on the Frame TV"  — no setup required.
struct ShowArtOnFrameIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Art on Frame TV"
    static var description = IntentDescription(
        "Generate AI art from a description and display it on your Samsung Frame TV.",
        categoryName: "Frame TV"
    )

    /// Set to false so the intent runs in the background — Siri doesn't
    /// need the app to be open. Generation + upload takes ~20–40 s;
    /// Siri will show a progress spinner while it runs.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Description", description: "What to show on the TV — be as specific as you like.")
    var artDescription: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Pull settings from UserDefaults (shared with the main app)
        let tvIP = UserDefaults.standard.string(forKey: "tv_ip") ?? ""
        guard !tvIP.isEmpty else {
            throw IntentError.tvIPNotSet
        }

        let providerRaw = UserDefaults.standard.string(forKey: "image_provider") ?? ""
        let provider    = ImageProvider(rawValue: providerRaw) ?? .pollinations
        let apiKey: String
        switch provider {
        case .openAI:      apiKey = UserDefaults.standard.string(forKey: "openai_api_key") ?? ""
        case .nanoBanana:  apiKey = UserDefaults.standard.string(forKey: "nb_api_key") ?? ""
        case .pollinations: apiKey = ""
        }
        let savedToken = UserDefaults.standard.string(forKey: "samsung_tv_token") ?? ""

        // Generate image
        let svc = DallEService()
        let (jpeg, _) = try await svc.generate(prompt: artDescription, apiKey: apiKey, provider: provider)
        let upscaled  = svc.upscaleTo4K(jpeg) ?? jpeg

        // Send to TV
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

        // Schedule auto-revert if enabled
        let autoRevert     = UserDefaults.standard.bool(forKey: "auto_revert")
        let revertMinutes  = UserDefaults.standard.integer(forKey: "revert_minutes")
        if autoRevert && revertMinutes > 0 {
            // Kick off a detached background task; this outlives the intent's perform()
            Task.detached {
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
        }

        return .result(dialog: "Sending \(artDescription) to the Frame TV now — it'll appear in about a minute.")
    }
}

// MARK: - Siri phrase registration

/// Registers automatic Siri phrases so users don't need to open Shortcuts.app first.
/// Requires iOS 16.4+ and app to be run at least once on device.
/// Siri will prompt "What would you like to show?" for the description parameter.
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

// MARK: - Intent errors

enum IntentError: LocalizedError {
    case tvIPNotSet

    var errorDescription: String? {
        switch self {
        case .tvIPNotSet:
            return "TV IP address not set — open Nanoframe and add it in Settings first."
        }
    }
}
