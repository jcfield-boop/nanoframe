# Source Photo Feature — Implementation Plan

Add a **source photo** input to the iOS app so the user can supply a reference image (a person, object, scene) and incorporate it into AI-generated artwork sent to the Frame TV.

---

## Current state

All image generation is pure **text-to-image**. `DallEService.generate(prompt:apiKey:provider:)` dispatches to one of four providers:

| Provider | Endpoint |
|---|---|
| Pollinations | `GET image.pollinations.ai/prompt/<text>` |
| Nano Banana | `POST nanobanana.expert/api/v1/generate` (JSON) |
| GPT Image 1 | `POST api.openai.com/v1/images/generations` (JSON → b64_json) |
| GPT Image 1 Mini | same |

No image data is ever sent upstream; only text prompts travel over the wire.

---

## Provider capability matrix

| Provider | Case | img2img | Mechanism | Why not |
|---|---|---|---|---|
| **GPT Image 1** | `.gptImage1` | **Yes** | `POST /v1/images/edits` multipart | — |
| **GPT Image 1 Mini** | `.gptImage1Mini` | **Yes** | same endpoint, smaller model | — |
| **Nano Banana** | `.nanoBanana` | **No** | JSON-only POST; no upload field | API has no image parameter |
| **Pollinations** | `.pollinations` | **No** | GET endpoint; `image_url` param exists but source is on-device | No upload path; data URIs exceed URL limits; local HTTP server is fragile |

### GPT Image 1 / Mini — full img2img ✅

OpenAI's `/v1/images/edits` endpoint accepts:

```
POST https://api.openai.com/v1/images/edits
Content-Type: multipart/form-data

image    = <PNG or JPEG bytes>   # source photo, ≤ 25 MB
prompt   = "..."
model    = gpt-image-1            # (or gpt-image-1-mini)
size     = 1536x1024              # landscape for Frame TV
n        = 1
quality  = high / medium
```

Without a mask, the entire image is the editable region — the model repaints the source subject into the described context. Both `gpt-image-1` and `gpt-image-1-mini` support this endpoint; the mini variant is faster and cheaper, full is higher quality. The response format is identical to `/v1/images/generations`: `data[0].b64_json`.

Swift's `Foundation` has no built-in multipart encoder; the body must be constructed manually (~30 lines, no dependency).

### Nano Banana — unsupported ✗

`POST /api/v1/generate` accepts a JSON body with exactly four fields: `prompt`, `aspect_ratio`, `resolution`, `output_format`. No image upload parameter is documented or available. Source photos are silently ignored; generation falls back to text-only.

### Pollinations — unsupported in practice ✗

The GET endpoint does accept an `image_url` query parameter, but the source photo lives on-device and is not reachable by URL. Options evaluated and rejected:

- **Base64 data URI** — a 4K photo encodes to ~8 MB of ASCII; URL query strings have a ~2 KB practical limit.
- **Temporary local HTTP server** — fragile, requires the Local Network entitlement (already present for a different purpose), and adds meaningful complexity for a free provider.

If Pollinations ever exposes a binary POST endpoint the service layer can be updated with no UI changes needed.

---

## Conditional UI design

### The `supportsSourcePhoto` property

Provider capability is declared on the enum itself, not scattered through the view or ViewModel. Add two computed properties to `ImageProvider` in `DallEService.swift`:

```swift
extension ImageProvider {
    /// Whether this provider's API can accept a source image for guided generation.
    var supportsSourcePhoto: Bool {
        switch self {
        case .gptImage1, .gptImage1Mini: return true
        case .pollinations, .nanoBanana:  return false
        }
    }

    /// Human-readable reason shown in the UI when supportsSourcePhoto == false.
    var sourcePhotoUnavailableReason: String {
        switch self {
        case .gptImage1, .gptImage1Mini:
            return ""
        case .pollinations:
            return "Pollinations uses a URL-based API that can't receive image uploads."
        case .nanoBanana:
            return "Nano Banana's API doesn't accept source images."
        }
    }
}
```

This is the single source of truth. The View reads `vm.provider.supportsSourcePhoto`; `DallEService` checks it to decide which endpoint to call; nothing else needs to know.

### UI behaviour — always show, disable with explanation (chosen approach)

Three options were considered:

| Option | Behaviour | Verdict |
|---|---|---|
| **A — Hide when unsupported** | Strip disappears when provider can't use it | ✗ User confused why the feature vanished after switching provider |
| **B — Always show, grey out** | Pickers disabled + one-line reason; photo kept if already loaded | ✅ Chosen |
| **C — Show but auto-clear** | Switching to incompatible provider silently drops the loaded photo | ✗ Destroys user data without warning |

**Option B** is the standard iOS pattern for unavailable features and keeps the layout stable as the user changes providers.

### Source photo strip — full state machine

```
Provider supports photo?
│
├── YES, no photo loaded
│   [ 📷 Camera ]  [ 🖼 Library ]  [ 📁 Files ]          (buttons enabled)
│
├── YES, photo loaded
│   [thumb] ×   "Using as reference for generation."
│
├── NO, no photo loaded
│   [ 📷 Camera ]  [ 🖼 Library ]  [ 📁 Files ]          (buttons .disabled(true), 40% opacity)
│   "Source photos require GPT Image 1 or GPT Image 1 Mini."
│
└── NO, photo already loaded (user switched provider after picking)
    [thumb] ×   ⚠ "[Provider] can't use source photos — prompt only."
                   (photo is kept; user decides whether to clear it or switch provider)
```

The ViewModel does **not** clear `sourcePhoto` when the provider changes. The user picked that photo intentionally; silently dropping it would be surprising. The warning is enough.

### Connecting provider to the `Generate` button

The Generate button is already disabled when `vm.prompt` is empty. No change needed there — when the provider doesn't support source photos, the button stays enabled and generation proceeds text-only, with the strip warning already visible before the tap.

The ViewModel's `generate()` method passes `sourcePhoto` to `DallEService.generate()`, which checks `provider.supportsSourcePhoto` internally and either routes to the edit endpoint or calls the standard text-only path.

---

## Architecture changes

### 1. `DallEService` — new method and signature

Add an optional `sourcePhoto: UIImage?` parameter to `generate()`:

```swift
func generate(
    prompt: String,
    apiKey: String,
    provider: ImageProvider,
    sourcePhoto: UIImage? = nil          // NEW
) async throws -> (jpeg: Data, image: UIImage)
```

When `sourcePhoto != nil` and the provider is `.gptImage1` or `.gptImage1Mini`:
- Call a new private method `gptImageEdit(prompt:apiKey:model:source:)` instead of `gptImageGen(…)`.
- The edit method resizes the source photo to ≤ 1536 px on the long axis, converts to PNG, builds a multipart body, and POSTs to `/v1/images/edits`.

When `sourcePhoto != nil` and the provider is `.pollinations` or `.nanoBanana`:
- Log a warning, proceed with text-only generation.
- Surface the warning to the user via a new `sourcePhotoWarning: String?` published property on the ViewModel.

**Multipart builder** (private helper, ~30 lines):

```swift
private func makeMultipart(boundary: String, fields: [(name: String, value: String)],
                            fileField: String, filename: String, mimeType: String,
                            data: Data) -> Data
```

No third-party dependency needed.

### 2. `AppViewModel` — new published state

```swift
@Published var sourcePhoto: UIImage?          // selected source image
@Published var sourcePhotoWarning: String?    // set when provider can't use it
```

`generate()` passes `sourcePhoto` through to the service and clears `sourcePhotoWarning` before each call. The ViewModel does NOT automatically clear `sourcePhoto` after generation — the user owns when to remove it.

---

## UI changes

### Source photo strip (new, in `ContentView`)

Insert a compact row **between** the image card and the prompt section. It is always visible (not hidden behind a toggle) so the user is always aware of whether a source photo is active.

**Empty state** — three icon buttons in a row:

```
[ 📷 Camera ]   [ 🖼 Photo Library ]   [ 📁 Files ]
```

**Loaded state** — thumbnail (square, ~64 pt, corner-radius 8) plus a clear (×) button, with the provider warning below if applicable:

```
[photo thumb] ×    Using as reference for generation.
                   ⚠ Nano Banana doesn't support source photos — prompt only.
```

Provider picker already lives in Settings; no changes needed there.

### Three input methods

#### A. Photo library — `PHPickerViewController`

`PHPickerViewController` (iOS 14+) does **not** require a runtime `NSPhotoLibraryUsageDescription` permission prompt — the system handles privacy via the picker UI. A `UIViewControllerRepresentable` wrapper exposes it as a SwiftUI `.photosPicker()` modifier or a sheet.

Recommended: use the SwiftUI `PhotosPicker` view (available iOS 16+, already within the app's deployment target) — zero UIKit bridging needed.

```swift
PhotosPicker(selection: $photoPickerItem, matching: .images) {
    Label("Photo Library", systemImage: "photo.on.rectangle.angled")
}
.onChange(of: photoPickerItem) { item in
    Task { vm.sourcePhoto = try? await item?.loadTransferable(type: UIImage.self) }
}
```

This is the simplest path and should be tried first.

#### B. Camera capture — `UIImagePickerController`

`UIImagePickerController` with `sourceType = .camera` wrapped in a `UIViewControllerRepresentable`. Requires:
- `NSCameraUsageDescription` added to `Info.plist` / `project.yml`
- Guard for `UIImagePickerController.isSourceTypeAvailable(.camera)` (simulator returns false; hide the button or show "Camera not available")

Coordinator pattern:

```swift
class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_:didFinishPickingMediaWithInfo:) { ... }
}
```

#### C. File import — `UIDocumentPickerViewController`

`UIDocumentPickerViewController` (or SwiftUI's `.fileImporter` modifier) lets users import JPEG/PNG/HEIC images from Files, iCloud Drive, or any connected storage provider.

```swift
.fileImporter(isPresented: $showFilePicker,
               allowedContentTypes: [.jpeg, .png, .heic]) { result in
    if let url = try? result.get(), url.startAccessingSecurityScopedResource() {
        vm.sourcePhoto = UIImage(data: (try? Data(contentsOf: url)) ?? Data())
        url.stopAccessingSecurityScopedResource()
    }
}
```

No special permission is required — security-scoped resources cover the access.

---

## Permissions changes

| Key | Where | Reason |
|---|---|---|
| `NSCameraUsageDescription` | `project.yml` → `Info.plist` properties | Camera source picker |
| `NSPhotoLibraryUsageDescription` | Already absent — NOT needed | `PhotosPicker` handles it internally |

Note: `NSPhotoLibraryAddUsageDescription` (write-only) is already present for saving to the Camera Roll.

---

## Image pre-processing before upload

The source photo from any picker is a raw `UIImage` of arbitrary size. Before sending to the API:

1. **Resize** so the long axis is ≤ 1536 px (API limit) and file size is < 25 MB.
2. **Convert** to PNG (for lossless alpha channel, required by some edit endpoints) or JPEG (smaller).
3. **Do NOT crop** — preserve the aspect ratio; the model handles composition.

A small helper in `DallEService`:

```swift
private func prepareSourceImage(_ image: UIImage, maxDimension: CGFloat = 1536) -> Data?
```

---

## Prioritised task list

### P1 — Core (required for any source photo generation)

| # | Task | File(s) touched |
|---|---|---|
| 1.0 | Add `supportsSourcePhoto` and `sourcePhotoUnavailableReason` to `ImageProvider` | `DallEService.swift` |
| 1.1 | Add `NSCameraUsageDescription` to `project.yml` | `ios/project.yml` |
| 1.2 | Add `sourcePhoto: UIImage?` to `AppViewModel`; remove `sourcePhotoWarning` (UI reads `provider.sourcePhotoUnavailableReason` directly) | `ContentView.swift` |
| 1.3 | Implement `prepareSourceImage(_:maxDimension:)` helper | `DallEService.swift` |
| 1.4 | Implement `makeMultipart(…)` helper | `DallEService.swift` |
| 1.5 | Implement `gptImageEdit(prompt:apiKey:model:source:)` private method | `DallEService.swift` |
| 1.6 | Wire `sourcePhoto` through public `generate()`; route to edit vs. generate based on `provider.supportsSourcePhoto` | `DallEService.swift` |

### P2 — Photo library picker (easiest input, enables end-to-end testing)

| # | Task | File(s) touched |
|---|---|---|
| 2.1 | Add `sourcePhotoStrip` view builder to `ContentView` | `ContentView.swift` |
| 2.2 | `PhotosPicker` button + `@State var photoPickerItem: PhotosPickerItem?` + `.onChange` loader | `ContentView.swift` |
| 2.3 | Thumbnail + clear button when `vm.sourcePhoto != nil` | `ContentView.swift` |
| 2.4 | Disable pickers + show `vm.provider.sourcePhotoUnavailableReason` when `!vm.provider.supportsSourcePhoto` | `ContentView.swift` |

### P3 — Camera capture

| # | Task | File(s) touched |
|---|---|---|
| 3.1 | `CameraPickerView: UIViewControllerRepresentable` | New file `CameraPickerView.swift` |
| 3.2 | Camera button in source photo strip (hidden on simulator) | `ContentView.swift` |

### P4 — File import

| # | Task | File(s) touched |
|---|---|---|
| 4.1 | `.fileImporter` modifier on `ContentView` | `ContentView.swift` |
| 4.2 | Files button in source photo strip | `ContentView.swift` |

### P5 — Polish

| # | Task | Notes |
|---|---|---|
| 5.1 | Accessibility labels on source photo strip buttons | — |
| 5.2 | HEIC → JPEG conversion for file-imported images | HEIC passes `UIImage(data:)` fine; output `jpegData` handles it |
| 5.3 | Update SPEC.md with source photo section | — |
| 5.4 | Siri Intent update — `ShowArtIntent` could accept an optional attachment, but Siri shortcuts don't easily pass photos; leave as text-only for now | — |

---

## Key risks and mitigations

| Risk | Mitigation |
|---|---|
| OpenAI `/v1/images/edits` response differs from `/v1/images/generations` | Both return `data[0].b64_json`; re-use existing `decode()` helper |
| Source photo too large (> 25 MB API limit) | `prepareSourceImage` enforces size; warn user if still too large after resize |
| `PhotosPicker` returns `nil` for some asset types (e.g. RAW) | Show error: "Unsupported image format — try JPEG or PNG" |
| Camera unavailable in simulator | Guard with `UIImagePickerController.isSourceTypeAvailable(.camera)` |
| User clears prompt after setting source photo | Source photo persists independently; both can be cleared via separate controls |

---

## Out of scope for this plan

- Android and macOS versions (img2img not currently planned for those platforms)
- Mask drawing / inpainting UI (selecting which part of the source photo to preserve)
- Multiple source photos
- Strength/influence slider (how much weight to give the source photo vs. the prompt)
