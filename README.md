# Nanoframe

**AI-generated art for your Samsung Frame TV** — type a prompt (or say one out loud), and Nanoframe generates an image and pushes it to the TV over your local network.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![iOS 16+](https://img.shields.io/badge/iOS-16%2B-blue)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)
![Samsung Frame](https://img.shields.io/badge/Samsung-Frame%20TV-1428A0)

---

## Platforms

| Platform | Location | Voice control |
|---|---|---|
| **macOS 14+** | `Sources/Nanoframe/` | Lango ESP32 voice assistant |
| **iOS 16+** | `ios/` | Native Siri App Intents |

---

## Features

- **Three image providers** — Pollinations.ai (free, no key), Nano Banana (native 4K), or DALL·E 3 (OpenAI)
- **Frame TV optimised prompts** — every prompt is automatically enhanced with display-specific guidance (wide colour gamut, high contrast, matte anti-glare panel, no HDR) before being sent to the provider
- **4K upscaling** — Pollinations and DALL·E images are upscaled to 3840×2160 before upload
- **Push to Frame TV** — uploads over WebSocket on your local network; handles Samsung's pairing flow automatically
- **Auto-revert** — optionally reverts to Samsung's art rotation after a configurable delay (5 min → 1 hour)
- **Siri voice control** (iOS) — two commands, no app required:
  - *"Show art on the Frame TV"* — generate and display
  - *"Resume art rotation"* — immediately revert to Samsung's slideshow
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

In Xcode: click the project → **NanoframeIOS** target → **Signing & Capabilities** → set your **Team** → add the **Siri** capability → run on your device or simulator.

On first launch, open **Settings** in the app and enter your TV's IP address.

### Siri commands

After running the app once, these phrases work with Siri — no Shortcuts setup needed:

| Say | What happens |
|---|---|
| *"Show art on the Frame TV with Nanoframe"* | Siri asks what to show, then generates and sends it |
| *"Resume art rotation with Nanoframe"* | Immediately reverts to Samsung's art slideshow |

Both commands run in the background — the app doesn't need to be open.

The revert command is scheduled via `BGTaskScheduler` so iOS wakes the app at the right time even if it has been killed. Timing is approximate but reliable.

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

On iOS, you can also just say *"Resume art rotation with Nanoframe"* to revert immediately.

Enable **Delete on revert** to remove Nanoframe-uploaded images from My Photos when reverting — only images uploaded by this app are ever deleted.

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
    NanoframeApp.swift          @main entry point + BGTaskScheduler registration
    ContentView.swift           SwiftUI UI + AppViewModel
    DallEService.swift          Image generation (UIKit version)
    SamsungArtClient.swift      Samsung Frame TV protocol (shared logic, no AppKit)
    Intents/
      ShowArtIntent.swift       Two Siri App Intents: show art + resume rotation
    Resources/
      Assets.xcassets/          App icon
      Info.plist                Local network + background task permissions
```

---

## Running the protocol tests

```bash
swift run ProtocolTests
```

Covers: WebSocket envelope format, inner request field injection, response parsing (all Samsung event types), TCP upload header construction, and edge cases.

---

## Samsung Frame TV protocol notes

Samsung's Frame TV art API is undocumented. Nanoframe was developed and tested against a **Samsung Frame TV LS03A** running firmware **T-NKM2AKUC-2301.1**.

Key discoveries:

- Control WebSocket: `ws://<tv-ip>:8001/api/v2/channels/com.samsung.art-app`
- Art requests use `ms.channel.emit` with `event: art_app_request`; the `data` field must be a **JSON-encoded string**, not an inline object
- `set_artmode_status` and `set_slideshow_status` are silently ignored on some firmware — to resume art rotation, fetch `get_content_list` (category `MY-C0004`) and `select_image` on any `SAM-*` content ID
- Image deletion is confirmed with `image_list_deleted`, not `image_deleted`
- Image upload uses a separate TCP connection on a port provided in the `ready_to_use` event; `conn_info` is itself a JSON-encoded string
- Both `id` and `request_id` must be present and equal in every request — newer firmware silently ignores requests missing `request_id`
- Content categories: `MY-C0002` = user uploads (`MY_F*` IDs), `MY-C0004` = Samsung Art Store (`SAM-*` IDs)

### Attributions

Protocol behaviour was cross-referenced against the [**samsungtvws**](https://github.com/xchwarze/samsung-tv-ws-api) Python library, which provided the critical insight that `request_id` must equal `id` in every request — newer Frame TV firmware silently drops requests that omit it.

---

## License

MIT
