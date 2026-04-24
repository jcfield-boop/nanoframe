import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nanoframe Help").font(.title2.bold())
                    Text("AI art for your Samsung Frame TV")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // ── Quick Start ────────────────────────────────────────
                    HelpSection("Quick Start", icon: "play.circle.fill", color: .green) {
                        HelpStep(n: 1, title: "Switch your TV to Art Mode") {
                            Text("Press the **Art** button on your Samsung remote, or go to **Source → The Frame**. The TV must be in Art/Frame Mode before you can send images — it will show your current art collection.")
                        }
                        HelpStep(n: 2, title: "Enter a prompt") {
                            Text("Describe the image you want. Be as specific or as loose as you like:")
                            CodeBlock("a misty Japanese mountain at dawn, watercolour")
                            CodeBlock("photo of a golden retriever surfing in Hawaii")
                        }
                        HelpStep(n: 3, title: "Generate") {
                            Text("Hit **Generate** and wait ~10–30 seconds. The image appears in the preview pane. Not happy with it? Generate again — each run uses a new random seed.")
                        }
                        HelpStep(n: 4, title: "Send to Frame TV") {
                            Text("Click **Send to Frame TV**. The app upscales to 4K, uploads over your local network, and displays the image. The whole process takes ~15–30 seconds.")
                        }
                    }

                    Divider()

                    // ── Image Providers ────────────────────────────────────
                    HelpSection("Image Providers", icon: "wand.and.stars", color: .purple) {
                        ProviderRow(
                            name: "Pollinations (free)",
                            icon: "leaf.fill", color: .green,
                            description: "No API key needed. Powered by the Flux model. Great quality for most subjects. Recommended for getting started."
                        )
                        ProviderRow(
                            name: "Nano Banana",
                            icon: "bolt.fill", color: .yellow,
                            description: "Returns native 4K images — no upscaling step. Requires an API key from nanobanana.expert."
                        )
                        ProviderRow(
                            name: "DALL·E 3 (OpenAI)",
                            icon: "sparkles", color: .blue,
                            description: "Highest prompt fidelity for complex scenes. Requires an OpenAI API key (sk-…). Images are generated at 1792×1024 and upscaled to 4K."
                        )
                    }

                    Divider()

                    // ── TV Setup ───────────────────────────────────────────
                    HelpSection("TV Setup", icon: "tv", color: .orange) {
                        HelpTip(icon: "network") {
                            Text("The Mac and Frame TV must be on the **same Wi-Fi network**.")
                        }
                        HelpTip(icon: "number") {
                            Text("Set the correct **TV IP address** in Settings. Find it on the TV under **Settings → General → Network → Network Status → IP Settings**.")
                        }
                        HelpTip(icon: "lock.open") {
                            Text("The first time you connect, your Samsung remote will show a **pairing prompt**. Accept it. The token is saved automatically so you won't be asked again.")
                        }
                        HelpTip(icon: "clock.arrow.circlepath") {
                            Text("**Revert to art rotation** in Settings controls how long your image stays before Samsung's own art rotation resumes. Default is 10 minutes. Set to Never to keep the image indefinitely.")
                        }
                    }

                    Divider()

                    // ── Voice / Lango ──────────────────────────────────────
                    HelpSection("Voice Control via Lango", icon: "mic.fill", color: .indigo) {
                        Text("If you have a **Lango ESP32 assistant** on your network, you can trigger Nanoframe by voice:")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach([
                                "Put a picture of X on the TV",
                                "Show a painting of X on the Frame",
                                "Change the art to X",
                                "Hang an image of X on the wall"
                            ], id: \.self) { phrase in
                                HStack(spacing: 8) {
                                    Image(systemName: "quote.bubble.fill")
                                        .foregroundStyle(.indigo.opacity(0.7))
                                        .font(.caption)
                                    Text(phrase).font(.callout.italic())
                                }
                            }
                        }
                        .padding(10)
                        .background(.indigo.opacity(0.07))
                        .cornerRadius(8)
                        HelpTip(icon: "exclamationmark.circle") {
                            Text("Nanoframe must be **open on your Mac** for voice triggers to work — it runs a local server on port 11436.")
                        }
                    }

                    Divider()

                    // ── Troubleshooting ────────────────────────────────────
                    HelpSection("Troubleshooting", icon: "wrench.and.screwdriver", color: .red) {
                        TroubleRow(
                            problem: "TV is unreachable",
                            fix: "Check the TV IP in Settings. Make sure the TV is on and connected to Wi-Fi. Try pinging it from Terminal: ping 192.168.0.24"
                        )
                        TroubleRow(
                            problem: "Upload times out or stalls",
                            fix: "Make sure the TV is in Art/Frame Mode (not regular TV mode). Switch to it with the Art button on your Samsung remote or Source → The Frame."
                        )
                        TroubleRow(
                            problem: "Pairing prompt never appears",
                            fix: "Delete the saved token in Settings (clear the TV IP field and re-enter it to force a fresh connection), then try again."
                        )
                        TroubleRow(
                            problem: "Image looks blurry or soft",
                            fix: "Switch to Nano Banana (native 4K) or DALL·E 3 in Settings. Pollinations images are upscaled from 1792×1024 which can look soft on very large screens."
                        )
                        TroubleRow(
                            problem: "Voice triggers not working",
                            fix: "Make sure Nanoframe is open. Check the console for '✅ RemoteTriggerServer listening on port 11436'. If another app grabbed port 11436, quit it and relaunch Nanoframe."
                        )
                        TroubleRow(
                            problem: "Art rotation doesn't resume",
                            fix: "The revert command requires the TV to be on and in Art Mode at the scheduled time. If the TV was off or switched modes, the revert is silently skipped — use the Samsung Art app to manually resume your slideshow."
                        )
                    }

                    // ── Debug log tip ──────────────────────────────────────
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("TV Debug Log").font(.caption.bold())
                            Text("The WebSocket log panel (below the image) shows every message sent to and received from the TV. Use **Copy All** to grab the full log for troubleshooting.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("A full log is also written to /tmp/nanoframe_tv.log")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(12)
                    .background(Color(.textBackgroundColor).opacity(0.5))
                    .cornerRadius(8)

                }
                .padding(24)
            }
        }
        .frame(width: 520, height: 640)
    }
}

// MARK: - Reusable components

private struct HelpSection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: () -> Content

    init(_ title: String, icon: String, color: Color, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.icon = icon; self.color = color; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(color)
            content()
        }
    }
}

private struct HelpStep<Content: View>: View {
    let n: Int
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 22, height: 22)
                Text("\(n)").font(.caption.bold()).foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.bold())
                content().font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct HelpTip<Content: View>: View {
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            content().font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct ProviderRow: View {
    let name: String
    let icon: String
    let color: Color
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.bold())
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TroubleRow: View {
    let problem: String
    let fix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
                Text(problem).font(.callout.bold())
            }
            Text(fix).font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 22)
        }
    }
}

private struct CodeBlock: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(.textBackgroundColor).opacity(0.8))
            .cornerRadius(5)
    }
}
