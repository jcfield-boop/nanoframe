# Nanoframe for iOS

Generate AI art by voice and send it to your Samsung Frame TV from iPhone or iPad.

**"Hey Siri, show a misty Japanese mountain on the Frame TV"** → generates the image → displays it automatically.

---

## Requirements

- iOS 16.0+
- Xcode 15+
- iPhone or iPad on the same Wi-Fi as the Frame TV
- [xcodegen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project (`brew install xcodegen`)

---

## Setup

```bash
# From the ios/ directory:
brew install xcodegen    # one-time
xcodegen generate        # creates NanoframeIOS.xcodeproj
open NanoframeIOS.xcodeproj
```

In Xcode:
1. Select the `NanoframeIOS` target → **Signing & Capabilities**
2. Set your **Team** (a free Apple ID works for personal device testing)
3. Add the **Siri** capability (click `+` → search "Siri")
4. Build and run on your iPhone/iPad

On first launch, open **Settings** in the app and enter your Frame TV's IP address.

---

## Siri integration

The app uses **App Intents** (iOS 16+) — no manual Shortcuts setup needed for basic usage.

### Automatic phrases (iOS 16.4+)
After running the app once, these phrases work with Siri without any setup:
- *"Show [description] on the Frame TV with Nanoframe"*
- *"Put [description] on my TV with Nanoframe"*
- *"Change the art to [description] with Nanoframe"*

### Shortcuts app
Open the **Shortcuts** app → search for "Show Art on Frame TV" → add it and record a custom phrase (e.g. just *"Frame TV"*). Then say *"Hey Siri, Frame TV"* and Siri will ask what to show.

### How it works
- `openAppWhenRun = false` — the intent runs entirely in the background; the app doesn't need to be open
- Generation takes 15–30 s depending on the provider; Siri shows a spinner
- Auto-revert runs via a detached background task when the intent completes

---

## Project structure

```
ios/
  project.yml                    xcodegen spec (generates .xcodeproj)
  NanoframeIOS.entitlements      Siri entitlement
  Sources/NanoframeIOS/
    NanoframeApp.swift           @main entry point
    ContentView.swift            SwiftUI UI + AppViewModel
    DallEService.swift           Image generation (UIKit, iOS version)
    SamsungArtClient.swift       Samsung Frame TV WebSocket + TCP protocol
    Intents/
      ShowArtIntent.swift        App Intent + AppShortcutsProvider
    Resources/
      Info.plist                 NSLocalNetworkUsageDescription
```

---

## Differences from the macOS version

| | macOS | iOS |
|---|---|---|
| Image types | `NSImage` / `NSBitmapImageRep` | `UIImage` / `.jpegData()` |
| Entry point | `Window` scene | `WindowGroup` scene |
| Siri | Not supported | App Intents (background execution) |
| Local server | Port 11436 for Lango triggers | Not needed — Siri replaces it |
| Settings | Side panel | Sheet |

`SamsungArtClient.swift` is identical between platforms (pure Foundation + Network).
