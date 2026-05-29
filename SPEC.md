# Nanoframe — Build Specification

A prompt-to-TV app: the user types (or speaks) a description, an AI image model generates the artwork, and the app pushes it directly to a Samsung Frame TV over the local network. Two native platforms: **macOS 14+** (Swift Package) and **iOS 16+** (Xcode project via xcodegen).

---

## What to build

### Core flow
1. User enters a text prompt
2. App sends the prompt (with Frame-TV-optimised suffix) to the chosen image provider
3. Response is decoded into a JPEG and upscaled to 3840×2160 if needed
4. App connects to the Samsung Frame TV via WebSocket, uploads the image over a secondary TCP connection, and instructs the TV to display it
5. After a configurable delay the app reverts the TV to its Samsung Art Store rotation
6. Every sent image is auto-saved to a local gallery

---

## Platforms

### macOS
- Language: Swift 5.9+, SwiftUI
- Minimum deployment: macOS 14 Sonoma
- Package manager: Swift Package Manager (`Package.swift`)
- Entry point: `NanoframeApp.swift` — single `Window` scene, `defaultSize(1160×720)`, `windowResizability(.contentMinSize)`
- Layout: `HSplitView` — left sidebar (270–310 pt) + right canvas (fills remainder)
- Settings: opened as a standalone `NSWindow` (460×560, resizable, min 420×380) via `NSHostingView` — **not** a SwiftUI sheet, which is constrained by the parent window

### iOS
- Language: Swift 5.9+, SwiftUI
- Minimum deployment: iOS 16.0
- Project generator: xcodegen (`project.yml` → `NanoframeIOS.xcodeproj`)
- Entry point: `NanoframeApp.swift` — registers `BGTaskScheduler` handler for `"com.nanoframe.revert"`
- Layout: `NavigationStack` → `ScrollView` with stacked cards
- Required permissions in `Info.plist`: `NSLocalNetworkUsageDescription`, `NSPhotoLibraryAddUsageDescription`, `NSBonjourServices: _samsungavrccommand._tcp`, `BGTaskSchedulerPermittedIdentifiers: com.nanoframe.revert`, `UIBackgroundModes: processing`
- Entitlement: Siri (`NSSiriUsageDescription` + Siri capability in Xcode)

---

## Image providers

All providers apply a Frame TV prompt enhancement suffix before sending. The same `ImageProvider` enum and `DallEService` struct exist on both platforms (NSImage on macOS, UIImage on iOS).

```swift
enum ImageProvider: String, CaseIterable {
    case pollinations  = "pollinations"
    case nanoBanana    = "nano-banana"
    case gptImage1     = "gpt-image-1"
    case gptImage1Mini = "gpt-image-1-mini"
}
```

### Prompt enhancement
Every prompt gets this suffix before being sent to any provider:
```
", highly detailed, 16:9 composition, wide color gamut, deep blacks,
rich saturated colors, high contrast, sharp fine detail,
professional photography or museum-quality art print,
optimised for matte anti-glare display, no HDR, no lens flare"
```

### Pollinations (free, no key)
- `GET https://image.pollinations.ai/prompt/<encoded>?width=1792&height=1024&model=flux&nologo=true&seed=<random>`
- Returns raw image bytes; upscale to 4K before upload

### Nano Banana
- `POST https://nanobanana.expert/api/v1/generate`
- Auth: `Bearer <key>`
- Body: `{ prompt, aspect_ratio: "16:9", resolution: "4k", output_format: "jpg" }`
- Response: `{ image_url: "..." }` → fetch image from that URL
- Returns native 4K; skip upscaling

### GPT Image 1 / GPT Image 1 Mini
- `POST https://api.openai.com/v1/images/generations`
- Auth: `Bearer <sk-...>`
- Body:
  ```json
  {
    "model": "gpt-image-1",
    "prompt": "...",
    "n": 1,
    "size": "1536x1024",
    "quality": "high",
    "output_format": "jpeg",
    "output_compression": 92
  }
  ```
- Use `"quality": "medium"` for the mini model
- Response: `{ data: [{ b64_json: "..." }] }` — decode base64 directly; there is no URL mode
- Upscale to 4K before upload

### 4K upscaling
```swift
func upscaleTo4K(_ jpegData: Data) -> Data? {
    // skip if width >= 3000
    // CIImage → scale to 3840×2160 → CGImage → JPEG at 0.92 quality
}
```

---

## Samsung Frame TV protocol

Tested on: Samsung Frame TV LS03A, firmware T-NKM2AKUC-2301.1.

### WebSocket connection
```
ws://<tv-ip>:8001/api/v2/channels/com.samsung.art-app?name=<base64("Nanoframe")>&token=<saved>
```
- On first connect, omit `token`; the TV responds with a token in `data.token` — save to UserDefaults
- After connect, drain one more message (`ms.channel.ready`) before sending any requests
- All messages use `URLSession.webSocketTask`; accept self-signed TLS via a `URLSessionDelegate` that calls `completionHandler(.useCredential, URLCredential(trust: trust))`

### Request envelope
Every art request is wrapped in this structure — **both `id` and `request_id` must be present and equal**; newer firmware silently ignores requests that omit `request_id`:
```json
{
  "method": "ms.channel.emit",
  "params": {
    "event": "art_app_request",
    "to": "host",
    "data": "<JSON-encoded-string of inner params>"
  }
}
```
The inner params always include:
```json
{ "id": "<clientId>", "request_id": "<clientId>", ...request-specific fields }
```

### Upload flow
1. Send `send_image` request with `file_type`, `file_size`, `image_date`, `matte_id: "none"`, and `conn_info: { d2d_mode: "socket", connection_id: <random int>, id: <clientId> }`
2. Wait for `ready_to_use` event — extract `conn_info.port` (arrives as a string) and `conn_info.key`
3. Open a plain TCP connection to `<tv-ip>:<port>`
4. Send a **length-prefixed JSON header** followed by raw JPEG bytes:
   - 4 bytes big-endian: byte-length of JSON header
   - JSON header: `{ num:0, total:1, fileLength:<bytes>, fileName:"dummy", fileType:"jpg", secKey:<key>, version:"0.0.1" }`
   - Raw JPEG data streamed in 64 KB chunks
5. Wait for `image_added` event → extract `content_id` (format `MY_F*`)
6. Send `select_image` with `content_id` and `show: true`

### Revert to art rotation
`set_artmode_status` is silently ignored on this firmware. The correct approach:
1. Send `get_content_list` for `category_id: "MY-C0002"`
2. Wait for `content_list` event; parse `content_list` field (may be a JSON-encoded string or a dict)
3. Find first item where `content_id` starts with `"SAM-"` and `category_id == "MY-C0004"`
4. Optionally send `delete_image_list` with `content_id_list: <JSON-array-string>` for tracked uploads; wait for `image_list_deleted`
5. Send `select_image` with the SAM-* content ID to restart the rotation

### Parsing responses
Every TV message has this structure:
```
{ method: "ms.channel.emit", params: { event: "d2d_service_message", data: "<JSON string>" } }
```
The inner data JSON contains the actual event fields. `conn_info` may itself be a JSON-encoded string. Parse defensively, handling both string and dict forms.

---

## AppViewModel

One `@MainActor ObservableObject` shared across the app. On macOS it's a `@StateObject` in ContentView. On iOS it's created in `@main` and injected as `@EnvironmentObject`.

### Key state
```swift
@Published var prompt: String
@Published var generatedImage: NSImage? / UIImage?
@Published var imageData: Data?
@Published var phase: Phase   // idle | generating | ready | sending | done
@Published var errorMessage: String?
@Published var sendStatus: String
@Published var uploadProgress: Double
@Published var revertAt: Date?

// Persisted settings — @Published with didSet writing to UserDefaults:
@Published var provider: ImageProvider
@Published var autoRevert: Bool        // default: true
@Published var revertMinutes: Int      // default: 10
@Published var deleteOnRevert: Bool    // default: false
@Published var showDebugLog: Bool      // default: false

// Plain computed vars (not @Published — don't drive UI controls):
var tvIP: String        // UserDefaults "tv_ip"
var savedToken: String  // UserDefaults "samsung_tv_token"
var apiKey: String      // UserDefaults "openai_api_key"
var nbKey: String       // UserDefaults "nb_api_key"
var uploadedContentIds: [String]  // UserDefaults array
```

**Important**: Settings that drive SwiftUI `Picker` and `Toggle` controls MUST be `@Published`. Plain computed vars backed by UserDefaults will cause the control to snap back to its previous value because SwiftUI never gets notified of the change.

### Key actions
- `generate()` — calls `DallEService.generate()`, sets `phase = .ready`
- `sendToTV()` — upscales, connects `SamsungArtClient`, uploads, saves to `ImageStore`, schedules revert if `autoRevert`
- `scheduleRevert(seconds:)` — stores `revertAt`, starts a `Task` that sleeps then calls `doRevert()`
- `revertNow()` — cancels pending task, calls `doRevert()` immediately
- `cancelRevert()` — cancels task, clears `revertAt`
- `keepOnTV()` — calls `cancelRevert()`, shows brief status message

---

## Auto-revert timer

```swift
func scheduleRevert(seconds: Int) {
    revertTask?.cancel()
    revertAt = Date().addingTimeInterval(Double(seconds))
    revertTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        guard !Task.isCancelled else { return }
        await self?.doRevert()
    }
}
```

On iOS, the revert is also scheduled via `BGProcessingTaskRequest(identifier: "com.nanoframe.revert")` with `earliestBeginDate` set, because `Task.detached` is killed by iOS after a few minutes when the app is backgrounded. The `BGTaskScheduler` handler in `NanoframeApp` calls the same `SamsungArtClient` revert logic.

UI shows a countdown using `TimelineView(.periodic(from: .now, by: 30))` and two inline buttons: **Keep** (cancel) and **Revert Now**.

---

## ImageStore (gallery)

Persists every sent image as a JPEG alongside a JSON metadata file.

```swift
struct GalleryItem: Codable, Identifiable {
    let id: UUID
    let prompt: String
    let date: Date
    var contentId: String   // TV content ID (MY_F*); empty if not yet on TV
    let filename: String    // local JPEG filename
}
```

Storage locations:
- macOS: `~/Library/Application Support/Nanoframe/`
- iOS: `<Documents>/nanoframe/`

API:
- `add(jpeg: Data, prompt: String, contentId: String) -> GalleryItem` — writes JPEG, inserts at index 0, persists JSON
- `setContentId(_:for:)` — update after upload completes
- `delete(_ item:)` — removes JPEG and updates JSON
- `image(for:) -> NSImage? / UIImage?` — reads JPEG on demand (not cached)
- `saveToFile(_:prompt:)` — macOS: `NSSavePanel`; iOS: `PHPhotoLibrary.performChanges`

Metadata is persisted as `gallery.json` in the same directory using `JSONEncoder/JSONDecoder`.

---

## Gallery UI

### macOS `GalleryView`
- Presented as a `.sheet` (this one is fine as a sheet — it has its own `minWidth: 600, minHeight: 460`)
- `LazyVGrid` with `.adaptive(minimum: 160)` columns
- Each `GalleryCell`: `ZStack` with image + gradient overlay + prompt/date text
- Right-click context menu: Load into editor / Send to TV / Save to file… / Delete…
- Delete uses `confirmationDialog` with two destructive options: gallery only, or gallery + TV
- Tapping a cell shows `ImageDetailView` as a sheet

### iOS `GalleryView`
- `NavigationStack` with `.navigationTitle("Gallery")`
- Same `LazyVGrid` pattern using `UIImage`
- Context menu on long-press: Send to TV / Delete
- `ImageDetailView`: full-image + Send to TV + Save to Photos buttons

---

## macOS-specific

### Sidebar layout
```
VStack {
    Header (title + provider subtitle)
    Divider
    ScrollView {
        Prompt TextEditor (minHeight 110, maxHeight 180)
        Generate button (borderedProminent)
        Send to Frame TV button (bordered)
        Upload progress (linear ProgressView)
        Revert countdown HStack (clock icon + TimelineView + Keep + Revert Now)
    }
    Spacer
    Divider
    Status bar HStack {
        Phase dot + label
        Spacer
        Copy to clipboard button (if image exists)
        Save to file button (if image exists)
        Gallery button
        Help button
        Settings button
    }
}
```

### Settings window
Opened via `NSHostingView` in a new `NSWindow` (not a SwiftUI sheet):
```swift
func openSettings() {
    if let existing = NSApp.windows.first(where: { $0.title == "Settings" }) {
        existing.makeKeyAndOrderFront(nil); return
    }
    let win = NSWindow(contentRect: NSRect(x:0,y:0,width:460,height:560),
                       styleMask: [.titled,.closable,.resizable,.miniaturizable],
                       backing: .buffered, defer: false)
    win.title = "Settings"
    win.center()
    win.contentView = NSHostingView(rootView: SettingsView(vm: vm))
    win.minSize = NSSize(width: 420, height: 380)
    win.makeKeyAndOrderFront(nil)
}
```
Settings content is a `ScrollView` wrapping two `GroupBox` sections (Image Generation + Samsung Frame TV).

### Remote trigger server
`RemoteTriggerServer` listens on `0.0.0.0:11436` for `POST /generate` with a JSON body `{ "prompt": "..." }`. On receipt, calls `vm.generateAndSend(prompt:)`. This allows a Lango ESP32 voice assistant to trigger art generation over the local network.

### macOS app icon
`AppIcon.icns` in `Sources/Nanoframe/Resources/`. Generated programmatically: dark navy background, TV frame outline with blue gradient, gold 4-point star sparkle. All sizes 16–1024 including `@2x`. Referenced in `Info.plist` via `CFBundleIconFile: AppIcon`.

Install to `/Applications`:
```bash
swift build -c release
mkdir -p /Applications/Nanoframe.app/Contents/{MacOS,Resources}
cp .build/release/Nanoframe /Applications/Nanoframe.app/Contents/MacOS/Nanoframe
cp Sources/Nanoframe/Resources/AppIcon.icns /Applications/Nanoframe.app/Contents/Resources/AppIcon.icns
# write Info.plist with CFBundleExecutable, CFBundleIdentifier, CFBundleIconFile, LSMinimumSystemVersion
```

---

## iOS-specific

### Siri App Intents (`ShowArtIntent.swift`)
Two intents in one file:

**`ShowArtOnFrameIntent`**
- `openAppWhenRun = false` — runs entirely in background
- Reads `tvIP`, `provider`, API keys from `UserDefaults`
- Returns a dialog string to Siri immediately (before doing any work)
- Kicks off `Task.detached` to generate + upload
- Schedules `BGProcessingTaskRequest(identifier: "com.nanoframe.revert")` with `earliestBeginDate` for auto-revert
- Phrase: `"Show art on the Frame TV with Nanoframe"`

**`RevertFrameTVIntent`**
- Cancels any pending `BGProcessingTask`
- Runs `SamsungArtClient.revertToSamsungArt()` in `Task.detached`
- Phrase: `"Resume art rotation with Nanoframe"`

**`NanoframeShortcuts: AppShortcutsProvider`** — registers both intents with static phrases. Do **not** use parameter interpolation (`\(\.$param)`) for `String` parameters — only `AppEntity`/`AppEnum` types are allowed by the framework.

### BGTaskScheduler
Registered in `NanoframeApp.init()`:
```swift
BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.nanoframe.revert", using: nil) { task in
    handleRevertTask(task as! BGProcessingTask)
}
```
The handler creates a `SamsungArtClient` from saved `UserDefaults` values and calls `revertToSamsungArt`.

### Save to Photos
```swift
func saveToPhotos(_ image: UIImage) async {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else { ... }
    try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.creationRequestForAsset(from: image)
    }
}
```
The Save button shows "Saved ✓" in green for 2 seconds after success and disables itself during that window.

---

## Swift concurrency notes

`NWConnection` state handlers fire on `DispatchQueue.global()` — any `var` they capture and mutate is unsafe under Swift 6 strict concurrency. Use a thread-safe once-guard instead of `var resolved`:

```swift
private final class Once: @unchecked Sendable {
    private var fired = false
    private let lock  = NSLock()
    func fire(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !fired else { return }
        fired = true; body()
    }
}

// Usage in checkReachable / tcpUpload:
let once = Once()
conn.stateUpdateHandler = { state in
    if case .ready = state { once.fire { cont.resume() } }
    if case .failed(let e) = state { once.fire { cont.resume(throwing: ...) } }
}
DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
    once.fire { cont.resume(throwing: ArtError.tvUnreachable) }
}
```

---

## File structure

```
Package.swift                          SPM manifest (macOS target + ProtocolTests target)
Sources/
  Nanoframe/
    NanoframeApp.swift                 @main, single Window scene
    ContentView.swift                  AppViewModel + main layout + SettingsView
    DallEService.swift                 ImageProvider enum + all provider implementations
    SamsungArtClient.swift             Full TV WebSocket + TCP protocol client
    ImageStore.swift                   Gallery persistence + NSImage.jpegData extension
    GalleryView.swift                  GalleryView + GalleryCell + ImageDetailView
    RemoteTriggerServer.swift          HTTP trigger server on port 11436
    HelpView.swift                     In-app help sheet
    Resources/
      AppIcon.icns                     macOS app icon (all sizes)
  ProtocolTests/
    main.swift                         Offline protocol validation suite

ios/
  project.yml                          xcodegen spec
  NanoframeIOS.entitlements            Siri entitlement
  Sources/NanoframeIOS/
    NanoframeApp.swift                 @main + BGTaskScheduler registration
    ContentView.swift                  AppViewModel + iOS layout + SettingsView
    DallEService.swift                 Same providers, UIImage variant
    SamsungArtClient.swift             Same protocol, Once helper for Swift 6 safety
    ImageStore.swift                   Gallery persistence, UIImage variant
    GalleryView.swift                  iOS gallery grid + detail sheet
    Intents/
      ShowArtIntent.swift              ShowArtOnFrameIntent + RevertFrameTVIntent + AppShortcutsProvider
    Resources/
      Assets.xcassets/
        AppIcon.appiconset/            iOS app icon
        AccentColor.colorset/          Required by xcodegen ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME
      Info.plist                       Generated by xcodegen from project.yml
```

---

## project.yml (xcodegen) key settings

```yaml
targets:
  NanoframeIOS:
    type: application
    platform: iOS
    deploymentTarget: "16.0"
    sources:
      - path: Sources/NanoframeIOS
        excludes: [Resources/Info.plist]
    resources:
      - Sources/NanoframeIOS/Resources
    info:
      properties:
        NSLocalNetworkUsageDescription: "..."
        NSPhotoLibraryAddUsageDescription: "..."
        NSBonjourServices: [_samsungavrccommand._tcp]
        BGTaskSchedulerPermittedIdentifiers: [com.nanoframe.revert]
        UIBackgroundModes: [processing]
    settings:
      base:
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
```

After running `xcodegen generate`, manually add the **Siri** capability in Xcode → target → Signing & Capabilities (xcodegen does not write entitlements correctly for Siri).

---

## Known TV behaviour quirks

| Observation | Detail |
|---|---|
| `set_artmode_status` ignored | Silently dropped on LS03A firmware; use `select_image` with a SAM-* ID instead |
| `request_id` required | Newer firmware silently ignores requests missing `request_id`; it must equal `id` |
| `conn_info` double-encoded | Arrives as a JSON-encoded string inside a JSON-encoded string in some firmware versions; parse defensively |
| `content_list` field | May be a JSON-encoded string or an already-decoded array |
| Deletion event | `image_list_deleted` (plural), not `image_deleted` |
| Upload port | Provided as a **string** in `conn_info.port`, not a number |
| Token | Assigned per-session by the TV on first connect; save and reuse |

---

## Attribution

Samsung Frame TV WebSocket protocol reverse-engineered with reference to:
- [samsungtvws](https://github.com/xchwarze/samsung-tv-ws-api) Python library — provided the critical insight that `request_id` must equal `id`
