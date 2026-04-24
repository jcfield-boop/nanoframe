# Nanoframe

**AI-generated art for your Samsung Frame TV** — type a prompt (or say one out loud), and Nanoframe generates an image and pushes it to the TV over your local network.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)
![Samsung Frame](https://img.shields.io/badge/Samsung-Frame%20TV-1428A0)

---

## Features

- **Three image providers** — Pollinations.ai (free, no key), Nano Banana (native 4K), or DALL·E 3 (OpenAI)
- **4K upscaling** — Pollinations and DALL·E images are upscaled to 3840×2160 before upload
- **Push to Frame TV** — uploads over WebSocket on your local network; handles Samsung's pairing flow automatically
- **Auto-revert** — optionally reverts to Samsung's own art rotation after a configurable delay (5 min → 1 hour)
- **Voice control** via [Lango](https://github.com/jcfield-boop/lango) — say *"put a painting of X on the TV"* and Nanoframe generates and displays it
- **TV debug log** — live WebSocket message panel for troubleshooting (toggle in Settings)
- **Protocol test suite** — `swift run ProtocolTests` validates every layer of the Samsung art wire format without touching a real TV

---

## Requirements

- macOS 14 Sonoma or later (SwiftUI + async/await throughout)
- Samsung Frame TV on the same Wi-Fi network
- The TV must be switched to **Art / Frame Mode** before sending images

---

## Quick start

```bash
git clone https://github.com/jcfield-boop/nanoframe
cd nanoframe
swift run Nanoframe
```

On first launch:

1. Open **Settings** (gear icon) and enter your Frame TV's IP address  
   *(TV → Settings → General → Network → Network Status → IP Settings)*
2. Optionally add an API key if you want Nano Banana or DALL·E 3 — Pollinations works with no key at all
3. Type a prompt, hit **Generate**, then **Send to Frame TV**

Your Samsung remote will show a pairing prompt the first time — accept it. The token is saved automatically.

---

## Image providers

| Provider | Key required | Resolution | Notes |
|---|---|---|---|
| **Pollinations** | None | 1792×1024 → 4K upscale | Free, Flux model, good for most subjects |
| **Nano Banana** | Yes ([nanobanana.expert](https://nanobanana.expert)) | Native 4K | No upscaling step, sharper on large screens |
| **DALL·E 3** | Yes (OpenAI `sk-…`) | 1792×1024 → 4K upscale | Best prompt fidelity for complex scenes |

---

## Auto-revert

Enable **Auto-revert** in Settings to automatically resume Samsung's art rotation after your image has been displayed. Choose a delay from 5 minutes to 1 hour. A countdown is shown in the main window and you can hit **Revert Now** at any time.

Enable **Delete on revert** to also remove Nanoframe-uploaded images from My Photos when the timer fires (only images uploaded by this app are ever deleted).

---

## Voice control (Lango integration)

If you run [Lango](https://github.com/jcfield-boop/lango) — an ESP32-S3 voice assistant — on your network, Nanoframe listens on **port 11436** for generation requests. Lango's `frame_tv` tool sends a POST with a prompt and Nanoframe generates and displays the image automatically.

Example voice phrases:
- *"Put a picture of puppies playing in a field on the TV"*
- *"Show a watercolour painting of Mount Fuji on the Frame"*
- *"Change the art to something calming and abstract"*

Nanoframe must be open on your Mac for voice triggers to work.

---

## Project layout

```
Sources/
  Nanoframe/
    NanoframeApp.swift          App entry point (SwiftUI @main)
    ContentView.swift           Main window + settings + generation flow
    DallEService.swift          Image generation (Pollinations / Nano Banana / DALL·E 3)
    SamsungArtClient.swift      Samsung Frame TV WebSocket + TCP upload protocol
    RemoteTriggerServer.swift   Local HTTP server for Lango voice triggers (port 11436)
    HelpView.swift              In-app help panel
  ProtocolTests/
    main.swift                  Protocol validation suite (no TV needed)
```

---

## Running the protocol tests

```bash
swift run ProtocolTests
```

Tests cover: WebSocket envelope format, inner request field injection, response parsing (all Samsung event types), TCP upload header construction, and edge cases.

---

## Samsung Frame TV protocol notes

Samsung's Frame TV art API is undocumented. A few things discovered during development:

- The control WebSocket is `ws://<tv-ip>:8001/api/v2/channels/samsung.remote.control`
- Art requests are sent as `ms.channel.emit` with `event: art_app_request`; the `data` field must be a **JSON-encoded string**, not an inline object
- `set_artmode_status` and `set_slideshow_status` are silently ignored on some firmware versions — to resume art rotation, use `get_content_list` (category `MY-C0004`) then `select_image` on any `SAM-*` content ID
- The TV confirms image deletion with `image_list_deleted`, not `image_deleted`
- Image upload uses a separate TCP connection on a port provided in the `ready_to_use` event; the `conn_info` field is itself a JSON-encoded string

---

## License

MIT
