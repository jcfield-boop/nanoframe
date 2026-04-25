# Nanoframe

**AI-generated art for your Samsung Frame TV** — type a prompt (or say one out loud), and Nanoframe generates an image and pushes it to the TV over your local network.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![iOS 16+](https://img.shields.io/badge/iOS-16%2B-blue)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)
![Samsung Frame](https://img.shields.io/badge/Samsung-Frame%20TV-1428A0)

---

## Platforms

| Platform | Location | Siri |
|---|---|---|
| **macOS 14+** | `Sources/Nanoframe/` | Via Lango ESP32 voice assistant |
| **iOS 16+** | `ios/` | Native App Intents — works hands-free |

---

## Features

- **Three image providers** — Pollinations.ai (free, no key), Nano Banana (native 4K), or DALL·E 3 (OpenAI)
- **Frame TV optimised prompts** — every prompt is automatically enhanced with display-specific guidance (wide gamut, high contrast, matte panel, no HDR) before being sent to the provider
- **4K upscaling** — Pollinations and DALL·E images are upscaled to 3840×2160 before upload
- **Push to Frame TV** — uploads over WebSocket on your local network; handles Samsung's pairing flow automatically
- **Auto-revert** — optionally reverts to Samsung's own art rotation after a configurable delay (5 min → 1 hour)
- **Siri voice control** (iOS) — say *"Show art on the Frame TV"* and Siri asks what to display; generates and sends without opening the app
- **Lango voice control** (macOS) — ESP32-S3 assistant triggers generation over the local network
- **TV debug log** — live WebSocket message panel for troubleshooting (toggle in Settings)
- **Protocol test suite** — `swift run ProtocolTests` validates every layer of the Samsung art wire format without touching a real TV

---

## macOS

### Requirements

- macOS 14 Sonoma or later
- Samsung Frame TV on the same Wi-Fi network
- TV must be in **Art / Frame Mode** before sending images

### Quick start

```bash
git clone https://github.com/jcfield-boop/nanoframe
cd nanoframe
swift run Nanoframe
```

On first launch, open **Settings** (gear icon) and enter your TV's IP address. Your Samsung remote will show a pairing prompt the first time — accept it.

---

## iOS

### Requirements

- iOS 16.0+
- Xcode 15+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Quick start

```bash
cd nanoframe/ios
xcodegen generate
open NanoframeIOS.xcodeproj
```

In Xcode: select the target → **Signing & Capabilities** → set your Team → add the **Siri** capability → run on your device or simulator.

### Siri

After running the app once, say any of these to Siri:

- *"Show art on the Frame TV with Nanoframe"*
- *"Put something on my TV with Nanoframe"*
- *"Change the Frame TV art with Nanoframe"*

Siri will ask *"What would you like to show?"*, then generate and send the image in the background — no need to open the app.

---

## Image providers

| Provider | Key required | Resolution | Notes |
|---|---|---|---|
| **Pollinations** | None | 1792×1024 → 4K upscale | Free, Flux model |
| **Nano Banana** | Yes ([nanobanana.expert](https://nanobanana.expert)) | Native 4K | No upscaling, sharpest on large screens |
| **DALL·E 3** | Yes (OpenAI `sk-…`) | 1792×1024 → 4K upscale | Best prompt fidelity |

API keys are entered in Settings and stored in UserDefaults on-device — never transmitted anywhere except directly to the chosen provider.

---

## Auto-revert

Enable **Auto-revert** in Settings to automatically resume Samsung's art rotation after a configurable delay (5 min → 1 hour). A countdown is shown and you can tap **Revert Now** at any time.

Enable **Delete on revert** to remove Nanoframe-uploaded images from My Photos when the timer fires — only images uploaded by this app are ever deleted.

---

## Project layout

```
Sources/
  Nanoframe/                    macOS app
    NanoframeApp.swift          App entry point
    ContentView.swift           Main window + settings + generation flow
    DallEService.swift          Image generation + Frame TV prompt enhancement
    SamsungArtClient.swift      Samsung Frame TV WebSocket + TCP upload protocol
    RemoteTriggerServer.swift   Local HTTP server for Lango voice triggers (port 11436)
    HelpView.swift              In-app help panel
  ProtocolTests/
    main.swift                  Protocol validation suite (no TV needed)

ios/
  project.yml                   xcodegen spec
  NanoframeIOS.entitlements     Siri entitlement
  Sources/NanoframeIOS/
    NanoframeApp.swift          @main entry point
    ContentView.swift           SwiftUI UI + AppViewModel
    DallEService.swift          Image generation (UIKit version)
    SamsungArtClient.swift      Samsung Frame TV protocol (shared logic, no AppKit)
    Intents/
      ShowArtIntent.swift       Siri App Intent + AppShortcutsProvider
    Resources/
      Assets.xcassets/          App icon
      Info.plist                Local network permission
```

---

## Running the protocol tests

```bash
swift run ProtocolTests
```

Covers: WebSocket envelope format, inner request field injection, response parsing (all Samsung event types), TCP upload header construction, and edge cases.

---

## Samsung Frame TV protocol notes

Samsung's Frame TV art API is undocumented. Key discoveries:

- Control WebSocket: `ws://<tv-ip>:8001/api/v2/channels/com.samsung.art-app`
- Art requests use `ms.channel.emit` with `event: art_app_request`; the `data` field must be a **JSON-encoded string**, not an inline object
- `set_artmode_status` and `set_slideshow_status` are silently ignored on some firmware — to resume art rotation, fetch `get_content_list` (category `MY-C0004`) and `select_image` on any `SAM-*` content ID
- Image deletion is confirmed with `image_list_deleted`, not `image_deleted`
- Image upload uses a separate TCP connection on a port provided in the `ready_to_use` event; `conn_info` is itself a JSON-encoded string
- Both `id` and `request_id` must be present and equal in every request — newer firmware silently ignores requests missing `request_id`

---

## License

MIT
