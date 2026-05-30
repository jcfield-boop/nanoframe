# Nanoframe — Build Specification

A prompt-to-TV app: the user types (or speaks) a description, an AI image model generates the artwork, and the app pushes it directly to a Samsung Frame TV over the local network. Three native platforms: **macOS 14+** (Swift Package), **iOS 16+** (Xcode project via xcodegen), and **Android 8+** (Kotlin + Jetpack Compose + Gradle).

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

## Android

### Platform overview

| Concept | Android equivalent |
|---|---|
| Swift / SwiftUI | Kotlin / Jetpack Compose |
| Swift Package Manager | Gradle (Kotlin DSL) |
| URLSession | OkHttp 4 |
| URLSession WebSocket | OkHttp `WebSocket` |
| NWConnection (TCP) | `java.net.Socket` |
| NSImage / UIImage / CIImage | `android.graphics.Bitmap` / `BitmapFactory` |
| UserDefaults | `SharedPreferences` (via `DataStore<Preferences>` recommended) |
| PHPhotoLibrary | `MediaStore` API |
| BGTaskScheduler | `WorkManager` |
| Siri App Intents | Google Assistant `AppActionsExtension` (or Android Shortcuts API) |
| `@Published ObservableObject` | `ViewModel` + `StateFlow<UiState>` |
| `NSHostingView` (standalone window) | Activity / Dialog Fragment |
| `xcodegen` + `project.yml` | Standard `build.gradle.kts` |

Minimum SDK: **26** (Android 8.0 Oreo). Target SDK: 35+.

---

### Project structure

```
app/
  build.gradle.kts
  src/main/
    AndroidManifest.xml
    java/com/nanoframe/
      MainActivity.kt              Entry point, NavHost
      ui/
        MainScreen.kt              Prompt input + Generate + Send buttons
        GalleryScreen.kt           LazyVerticalGrid gallery
        SettingsScreen.kt          Settings composable
      viewmodel/
        AppViewModel.kt            ViewModel + UiState StateFlow
      service/
        ImageGenService.kt         All 4 image providers (OkHttp)
        SamsungArtClient.kt        WebSocket + TCP upload client
        ImageStore.kt              Gallery persistence
      worker/
        RevertWorker.kt            WorkManager Worker for background revert
      intents/
        ShowArtAction.kt           Google Assistant action handler
    res/
      drawable/                    Vector icons
      mipmap-*/                    App icon densities (48/72/96/144/192 dp)
      values/
        strings.xml
        themes.xml                 Material3 theme
```

---

### Gradle dependencies (`build.gradle.kts`)

```kotlin
dependencies {
    // Compose BOM
    implementation(platform("androidx.compose:compose-bom:2024.05.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.0")
    implementation("androidx.navigation:navigation-compose:2.7.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.0")

    // Networking
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // Image display
    implementation("io.coil-kt:coil-compose:2.6.0")

    // Persistence
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // Background work
    implementation("androidx.work:work-runtime-ktx:2.9.0")
}
```

---

### AndroidManifest.xml — required entries

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
    android:maxSdkVersion="28" />
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />

<application ...>
    <!-- WorkManager provider — required for WorkManager to initialise -->
    <provider
        android:name="androidx.startup.InitializationProvider"
        android:authorities="${applicationId}.androidx-startup"
        android:exported="false">
        <meta-data android:name="androidx.work.impl.WorkManagerInitializer"
            android:value="androidx.startup" />
    </provider>

    <!-- Google Assistant action (optional) -->
    <meta-data
        android:name="com.google.android.actions"
        android:resource="@xml/actions" />
</application>
```

For local network access (Samsung TV on LAN) no additional permission is needed on Android; the `INTERNET` permission covers LAN sockets.

---

### AppViewModel

```kotlin
data class UiState(
    val prompt: String = "",
    val bitmap: Bitmap? = null,
    val jpegBytes: ByteArray? = null,
    val phase: Phase = Phase.Idle,
    val errorMessage: String? = null,
    val sendStatus: String = "",
    val uploadProgress: Float = 0f,
    val revertAt: Instant? = null
)

enum class Phase { Idle, Generating, Ready, Sending, Done }

class AppViewModel(application: Application) : AndroidViewModel(application) {

    private val prefs = PreferenceManager.getDefaultSharedPreferences(application)
    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    // Settings backed by SharedPreferences
    var provider: ImageProvider
        get() = ImageProvider.fromRaw(prefs.getString("image_provider", "pollinations")!!)
        set(v) { prefs.edit { putString("image_provider", v.raw) } }

    var autoRevert: Boolean
        get() = prefs.getBoolean("auto_revert", true)
        set(v) { prefs.edit { putBoolean("auto_revert", v) } }

    var revertMinutes: Int
        get() = prefs.getInt("revert_minutes", 10)
        set(v) { prefs.edit { putInt("revert_minutes", v) } }

    // ... tvIP, apiKey, etc.

    fun generate() {
        viewModelScope.launch {
            _state.update { it.copy(phase = Phase.Generating, errorMessage = null) }
            runCatching {
                val svc = ImageGenService()
                val (jpeg, bitmap) = svc.generate(
                    prompt = state.value.prompt,
                    apiKey  = activeApiKey(),
                    provider = provider
                )
                _state.update { it.copy(phase = Phase.Ready, jpegBytes = jpeg, bitmap = bitmap) }
            }.onFailure { e ->
                _state.update { it.copy(phase = Phase.Idle, errorMessage = e.message) }
            }
        }
    }

    fun sendToTV() {
        viewModelScope.launch {
            _state.update { it.copy(phase = Phase.Sending) }
            runCatching {
                val jpeg     = upscaleTo4K(state.value.jpegBytes!!) ?: state.value.jpegBytes!!
                val client   = SamsungArtClient(tvIP, prefs.getString("samsung_tv_token","")!!)
                client.checkReachable()
                client.connect()
                if (client.token.isNotEmpty()) prefs.edit { putString("samsung_tv_token", client.token) }
                val contentId = client.uploadAndDisplay(jpeg) { progress ->
                    _state.update { it.copy(uploadProgress = progress) }
                }
                ImageStore(getApplication()).add(jpeg, state.value.prompt, contentId)
                _state.update { it.copy(phase = Phase.Done, sendStatus = "On TV!") }
                if (autoRevert) scheduleRevert(revertMinutes * 60)
            }.onFailure { e ->
                _state.update { it.copy(phase = Phase.Ready, errorMessage = e.message) }
            }
        }
    }
}
```

**Important**: Jetpack Compose re-renders on `StateFlow` collection, but individual settings fields backed by `SharedPreferences` are **not** observable. For the Settings screen use a `SettingsViewModel` that holds `MutableStateFlow` for each field and writes through to `SharedPreferences` in `set` — same principle as the `@Published var … { didSet }` pattern on iOS.

---

### ImageGenService (Kotlin/OkHttp)

All 4 providers use `OkHttpClient` with a 60s timeout. Apply the same Frame TV prompt enhancement suffix as the Swift version.

```kotlin
class ImageGenService {
    private val client = OkHttpClient.Builder()
        .callTimeout(60, TimeUnit.SECONDS)
        .build()

    suspend fun generate(prompt: String, apiKey: String, provider: ImageProvider): Pair<ByteArray, Bitmap> =
        withContext(Dispatchers.IO) {
            val enhanced = enhanceForFrameTV(prompt)
            when (provider) {
                ImageProvider.POLLINATIONS   -> pollinations(enhanced)
                ImageProvider.NANO_BANANA    -> nanoBanana(enhanced, apiKey)
                ImageProvider.GPT_IMAGE_1    -> gptImageGen(enhanced, apiKey, "gpt-image-1")
                ImageProvider.GPT_IMAGE_MINI -> gptImageGen(enhanced, apiKey, "gpt-image-1-mini")
            }
        }

    private fun pollinations(prompt: String): Pair<ByteArray, Bitmap> {
        val seed = (1..999_999).random()
        val url  = "https://image.pollinations.ai/prompt/${prompt.urlEncode()}" +
                   "?width=1792&height=1024&model=flux&nologo=true&seed=$seed"
        val bytes = client.newCall(Request.Builder().url(url).build()).execute()
            .use { check(it.isSuccessful); it.body!!.bytes() }
        return Pair(bytes, BitmapFactory.decodeByteArray(bytes, 0, bytes.size)!!)
    }

    private fun gptImageGen(prompt: String, apiKey: String, model: String): Pair<ByteArray, Bitmap> {
        val quality = if (model.endsWith("mini")) "medium" else "high"
        val body = JSONObject().apply {
            put("model", model); put("prompt", prompt); put("n", 1)
            put("size", "1536x1024"); put("quality", quality)
            put("output_format", "jpeg"); put("output_compression", 92)
        }.toString().toRequestBody("application/json".toMediaType())
        val resp = client.newCall(
            Request.Builder()
                .url("https://api.openai.com/v1/images/generations")
                .header("Authorization", "Bearer $apiKey")
                .post(body).build()
        ).execute().use { check(it.isSuccessful); it.body!!.string() }
        val b64   = JSONObject(resp).getJSONArray("data").getJSONObject(0).getString("b64_json")
        val bytes = Base64.decode(b64, Base64.DEFAULT)
        return Pair(bytes, BitmapFactory.decodeByteArray(bytes, 0, bytes.size)!!)
    }
    // nanoBanana: same POST pattern as Swift version; same response shape { image_url }
}
```

---

### SamsungArtClient (Kotlin/OkHttp WebSocket)

The WebSocket envelope, request_id requirement, TCP wire format, and revert logic are **identical** to the Swift version (see [Samsung Frame TV protocol](#samsung-frame-tv-protocol) above). Only the implementation language differs.

```kotlin
class SamsungArtClient(private val host: String, private var savedToken: String) {
    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS) // keep alive for WebSocket
        .hostnameVerifier { _, _ -> true }     // TV uses self-signed cert
        .build()

    var token = savedToken
    private var ws: WebSocket? = null
    private val messages = Channel<String>(Channel.UNLIMITED)

    suspend fun connect() = withContext(Dispatchers.IO) {
        val name = Base64.encodeToString("Nanoframe".toByteArray(), Base64.NO_WRAP)
        val url  = buildString {
            append("wss://$host:8002/api/v2/channels/com.samsung.art-app")
            append("?name=$name")
            if (savedToken.isNotEmpty()) append("&token=$savedToken")
        }
        suspendCancellableCoroutine { cont ->
            val listener = object : WebSocketListener() {
                override fun onOpen(ws: WebSocket, r: Response) {
                    this@SamsungArtClient.ws = ws
                    cont.resume(Unit)
                }
                override fun onMessage(ws: WebSocket, text: String) {
                    messages.trySend(text)
                    // Parse token from data.token on first message
                    runCatching {
                        val d = JSONObject(text).getJSONObject("data")
                        if (d.has("token")) token = d.getString("token")
                    }
                }
                override fun onFailure(ws: WebSocket, t: Throwable, r: Response?) =
                    cont.resumeWithException(t)
            }
            client.newWebSocket(Request.Builder().url(url).build(), listener)
        }
        // drain ready message
        withTimeoutOrNull(3000) { messages.receive() }
    }

    private suspend fun sendArtRequest(params: JSONObject) {
        val inner = params.toString()
        val outer = JSONObject().apply {
            put("method", "ms.channel.emit")
            put("params", JSONObject().apply {
                put("event", "art_app_request")
                put("to", "host")
                put("data", inner)     // double-encoded: inner is a JSON string
            })
        }
        ws!!.send(outer.toString())
    }

    // uploadAndDisplay, revertToSamsungArt: same logic as Swift, translated to Kotlin
    // TCP upload: use java.net.Socket, DataOutputStream for 4-byte big-endian length prefix

    suspend fun tcpUpload(host: String, port: Int, key: String, jpeg: ByteArray,
                          onProgress: (Float) -> Unit) = withContext(Dispatchers.IO) {
        val header = JSONObject().apply {
            put("num", 0); put("total", 1); put("fileLength", jpeg.size)
            put("fileName", "dummy"); put("fileType", "jpg")
            put("secKey", key); put("version", "0.0.1")
        }.toString().toByteArray(Charsets.UTF_8)

        Socket(host, port).use { sock ->
            val out = DataOutputStream(sock.getOutputStream())
            out.writeInt(header.size)          // 4-byte big-endian length
            out.write(header)
            val chunkSize = 65_536
            var sent = 0
            while (sent < jpeg.size) {
                val end = minOf(sent + chunkSize, jpeg.size)
                out.write(jpeg, sent, end - sent)
                sent = end
                onProgress(sent.toFloat() / jpeg.size)
            }
            out.flush()
        }
    }

    fun disconnect() { ws?.close(1000, null) }
}
```

---

### ImageStore (Android)

```kotlin
data class GalleryItem(
    val id: String = UUID.randomUUID().toString(),
    val prompt: String,
    val date: String,      // ISO-8601
    var contentId: String,
    val filename: String
)

class ImageStore(private val context: Context) {
    private val dir = File(context.filesDir, "nanoframe").also { it.mkdirs() }
    private val metaFile = File(dir, "gallery.json")

    fun add(jpeg: ByteArray, prompt: String, contentId: String): GalleryItem {
        val item = GalleryItem(prompt = prompt,
            date = Instant.now().toString(), contentId = contentId,
            filename = "${UUID.randomUUID()}.jpg")
        File(dir, item.filename).writeBytes(jpeg)
        val items = loadAll().toMutableList().also { it.add(0, item) }
        persist(items)
        return item
    }

    fun bitmap(item: GalleryItem): Bitmap? =
        BitmapFactory.decodeFile(File(dir, item.filename).absolutePath)

    fun saveToMediaStore(jpeg: ByteArray, prompt: String) {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "${prompt.take(40)}.jpg")
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Nanoframe")
        }
        val uri = context.contentResolver.insert(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)!!
        context.contentResolver.openOutputStream(uri)!!.use { it.write(jpeg) }
    }

    // loadAll(), persist(), delete(): standard JSON serialisation via Gson or kotlinx.serialization
}
```

---

### Auto-revert — WorkManager

Because Android kills background coroutines when the app is backgrounded, use `WorkManager` for the revert — same rationale as `BGTaskScheduler` on iOS.

```kotlin
class RevertWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
        val tvIP  = prefs.getString("tv_ip", "") ?: return Result.failure()
        val token = prefs.getString("samsung_tv_token", "") ?: ""
        val ids   = if (prefs.getBoolean("delete_on_revert", false))
            prefs.getStringSet("nanoframe_content_ids", emptySet())!!.toList() else emptyList()
        return runCatching {
            val client = SamsungArtClient(tvIP, token)
            client.checkReachable()
            client.connect()
            client.revertToSamsungArt(deleteIds = ids)
            client.disconnect()
            Result.success()
        }.getOrElse { Result.retry() }
    }
}

// Schedule from AppViewModel:
fun scheduleRevert(delaySeconds: Int) {
    val request = OneTimeWorkRequestBuilder<RevertWorker>()
        .setInitialDelay(delaySeconds.toLong(), TimeUnit.SECONDS)
        .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
        .addTag("nanoframe_revert")
        .build()
    WorkManager.getInstance(getApplication())
        .enqueueUniqueWork("nanoframe_revert", ExistingWorkPolicy.REPLACE, request)
}

fun cancelRevert() {
    WorkManager.getInstance(getApplication()).cancelAllWorkByTag("nanoframe_revert")
}
```

Register `RevertWorker` in `AndroidManifest.xml` via the WorkManager `<provider>` (see manifest section above).

---

### Settings — Compose

Settings that drive `Spinner`/`Switch` controls must flow through `StateFlow`, not raw `SharedPreferences` reads, or the control will snap back on recomposition:

```kotlin
class SettingsViewModel(app: Application) : AndroidViewModel(app) {
    private val prefs = PreferenceManager.getDefaultSharedPreferences(app)

    private val _provider = MutableStateFlow(
        ImageProvider.fromRaw(prefs.getString("image_provider", "pollinations")!!)
    )
    val provider: StateFlow<ImageProvider> = _provider

    fun setProvider(p: ImageProvider) {
        _provider.value = p
        prefs.edit { putString("image_provider", p.raw) }
    }
    // autoRevert, revertMinutes, deleteOnRevert: same pattern
}

@Composable
fun SettingsScreen(vm: SettingsViewModel = viewModel()) {
    val provider by vm.provider.collectAsStateWithLifecycle()
    // ...
    ExposedDropdownMenuBox(...) {
        ImageProvider.entries.forEach { p ->
            DropdownMenuItem(
                text = { Text(p.displayName) },
                onClick = { vm.setProvider(p) }
            )
        }
    }
}
```

---

### 4K upscaling (Android)

```kotlin
fun upscaleTo4K(jpeg: ByteArray): ByteArray {
    val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
    if (bmp.width >= 3000) return jpeg
    val scaled = Bitmap.createScaledBitmap(bmp, 3840, 2160, true)
    return ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, 92, it) }.toByteArray()
}
```

---

### Google Assistant action (optional)

`res/xml/actions.xml`:
```xml
<actions>
  <action intentName="actions.intent.CREATE_THING">
    <fulfillment urlTemplate="nanoframe://generate{?prompt}">
      <parameter-mapping intentParameter="thing.name" urlParameter="prompt"/>
    </fulfillment>
  </action>
</actions>
```
Handle the deep link in `MainActivity`:
```kotlin
intent?.data?.getQueryParameter("prompt")?.let { vm.generateAndSend(it) }
```
This is less tightly integrated than iOS Siri App Intents — it opens the app rather than running silently in background.

---

### App icon sizes

| Folder | Size |
|---|---|
| `mipmap-mdpi` | 48×48 |
| `mipmap-hdpi` | 72×72 |
| `mipmap-xhdpi` | 96×96 |
| `mipmap-xxhdpi` | 144×144 |
| `mipmap-xxxhdpi` | 192×192 |
| `mipmap-anydpi-v26` | `ic_launcher.xml` adaptive icon (foreground + background layers) |

---

## Attribution

Samsung Frame TV WebSocket protocol reverse-engineered with reference to:
- [samsungtvws](https://github.com/xchwarze/samsung-tv-ws-api) Python library — provided the critical insight that `request_id` must equal `id`
