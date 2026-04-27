import SwiftUI
import Photos
import BackgroundTasks

// MARK: - ViewModel

@MainActor
class AppViewModel: ObservableObject {
    @Published var prompt = ""
    @Published var generatedImage: UIImage?
    @Published var imageData: Data?
    @Published var phase: Phase = .idle
    @Published var errorMessage: String?
    @Published var sendStatus: String = ""
    @Published var uploadProgress: Double = 0
    @Published var tvLog: [String] = []
    @Published var revertAt: Date? = nil

    // MARK: Persisted settings

    var uploadedContentIds: [String] {
        get { UserDefaults.standard.stringArray(forKey: "nanoframe_content_ids") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "nanoframe_content_ids") }
    }
    var deleteOnRevert: Bool {
        get { UserDefaults.standard.object(forKey: "delete_on_revert") == nil
                ? false : UserDefaults.standard.bool(forKey: "delete_on_revert") }
        set { UserDefaults.standard.set(newValue, forKey: "delete_on_revert") }
    }
    var autoRevert: Bool {
        get { UserDefaults.standard.object(forKey: "auto_revert") == nil
                ? true : UserDefaults.standard.bool(forKey: "auto_revert") }
        set { UserDefaults.standard.set(newValue, forKey: "auto_revert") }
    }
    var revertMinutes: Int {
        get { let v = UserDefaults.standard.integer(forKey: "revert_minutes"); return v == 0 ? 10 : v }
        set { UserDefaults.standard.set(newValue, forKey: "revert_minutes") }
    }
    var showDebugLog: Bool {
        get { UserDefaults.standard.object(forKey: "show_debug_log") == nil
                ? false : UserDefaults.standard.bool(forKey: "show_debug_log") }
        set { UserDefaults.standard.set(newValue, forKey: "show_debug_log") }
    }
    var provider: ImageProvider {
        get { ImageProvider(rawValue: UserDefaults.standard.string(forKey: "image_provider") ?? "") ?? .pollinations }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "image_provider") }
    }
    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "openai_api_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "openai_api_key") }
    }
    var nbKey: String {
        get { UserDefaults.standard.string(forKey: "nb_api_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "nb_api_key") }
    }
    var tvIP: String {
        get { UserDefaults.standard.string(forKey: "tv_ip") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "tv_ip") }
    }
    var savedToken: String {
        get { UserDefaults.standard.string(forKey: "samsung_tv_token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "samsung_tv_token") }
    }

    // MARK: Phase

    enum Phase: Equatable {
        case idle, generating, ready, sending, done
        var isWorking: Bool { self == .generating || self == .sending }
        var label: String {
            switch self {
            case .idle:       return "Describe what to show on the Frame TV"
            case .generating: return "Generating image…"
            case .ready:      return "Image ready"
            case .sending:    return "Uploading to Frame TV…"
            case .done:       return "Now displaying on Frame TV ✓"
            }
        }
    }

    private let svc = DallEService()
    private var revertTask: Task<Void, Never>?

    var activeKey: String {
        switch provider {
        case .pollinations: return "free"
        case .nanoBanana:   return nbKey
        case .openAI:       return apiKey
        }
    }

    // MARK: Actions

    func generate() async {
        cancelRevert()
        phase = .generating
        errorMessage = nil
        do {
            let (data, image) = try await svc.generate(
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: activeKey,
                provider: provider
            )
            imageData = data
            generatedImage = image
            phase = .ready
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    func sendToTV() async {
        guard let data = imageData else { return }
        cancelRevert()
        phase = .sending
        sendStatus = "Upscaling to 4K…"
        uploadProgress = 0
        errorMessage = nil
        do {
            let upscaled = svc.upscaleTo4K(data) ?? data
            let sizeMB = String(format: "%.1f", Double(upscaled.count) / 1_048_576)
            let client = SamsungArtClient(host: tvIP, savedToken: savedToken)
            tvLog = []
            client.onProgress = { [weak self] msg in
                Task { @MainActor [weak self] in self?.sendStatus = msg }
            }
            client.onUploadProgress = { [weak self] fraction in
                Task { @MainActor [weak self] in self?.uploadProgress = fraction }
            }
            client.onRawMessage = { [weak self] raw in
                let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                Task { @MainActor [weak self] in
                    self?.tvLog.append("[\(ts)] \(raw)")
                }
            }
            sendStatus = "Checking TV is reachable…"
            try await client.checkReachable()
            sendStatus = "Connecting to Frame TV…"
            try await client.connect()
            if !client.token.isEmpty { savedToken = client.token }
            sendStatus = "Uploading \(sizeMB) MB…"
            let contentId = try await client.uploadAndDisplay(upscaled)
            if !contentId.isEmpty {
                uploadedContentIds = uploadedContentIds + [contentId]
            }
            // Save to local gallery
            let galleryItem = ImageStore.shared.add(
                jpeg: upscaled,
                prompt: prompt,
                contentId: contentId
            )
            uploadProgress = 1
            phase = .done
            sendStatus = "Displayed on Frame TV ✓"
            if autoRevert { scheduleRevert(seconds: revertMinutes * 60) }
            try await Task.sleep(nanoseconds: 4_000_000_000)
            if phase == .done { phase = .ready; sendStatus = "" }
        } catch {
            errorMessage = "TV error: \(error.localizedDescription)"
            sendStatus = ""
            uploadProgress = 0
            phase = .ready
        }
    }

    func selectOnTV(contentId: String) async {
        cancelRevert()
        phase = .sending
        sendStatus = "Connecting to Frame TV…"
        errorMessage = nil
        do {
            let client = SamsungArtClient(host: tvIP, savedToken: savedToken)
            tvLog = []
            client.onRawMessage = { [weak self] raw in
                let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                Task { @MainActor [weak self] in self?.tvLog.append("[\(ts)] \(raw)") }
            }
            try await client.checkReachable()
            try await client.connect()
            if !client.token.isEmpty { savedToken = client.token }
            sendStatus = "Selecting image…"
            try await client.selectExisting(contentId)
            if !uploadedContentIds.contains(contentId) {
                uploadedContentIds = uploadedContentIds + [contentId]
            }
            phase = .done
            sendStatus = "Displayed on Frame TV ✓"
            if autoRevert { scheduleRevert(seconds: revertMinutes * 60) }
            try await Task.sleep(nanoseconds: 4_000_000_000)
            if phase == .done { phase = .ready; sendStatus = "" }
        } catch {
            errorMessage = "TV error: \(error.localizedDescription)"
            sendStatus = ""
            uploadProgress = 0
            phase = .ready
        }
    }

    // MARK: Save to Photos

    func saveToPhotos(_ image: UIImage) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            errorMessage = "Photos access denied — enable it in Settings."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        } catch {
            errorMessage = "Couldn't save to Photos: \(error.localizedDescription)"
        }
    }

    // MARK: Keep on TV (cancel pending revert)

    func keepOnTV() {
        cancelRevert()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "com.nanoframe.revert")
        sendStatus = "Keeping on TV — art rotation paused."
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if sendStatus == "Keeping on TV — art rotation paused." { sendStatus = "" }
        }
    }

    /// Called by the Siri App Intent — generates and sends without needing the UI open.
    func generateAndSend(prompt: String) async {
        self.prompt = prompt
        await generate()
        guard phase == .ready else { return }
        await sendToTV()
    }

    // MARK: Revert

    func scheduleRevert(seconds: Int) {
        revertTask?.cancel()
        revertAt = Date().addingTimeInterval(Double(seconds))
        revertTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.doRevert()
        }
    }

    func revertNow() {
        revertTask?.cancel()
        revertAt = nil
        sendStatus = "Reverting to art rotation…"
        revertTask = Task { [weak self] in
            guard let self else { return }
            await self.doRevert()
        }
    }

    func cancelRevert() {
        revertTask?.cancel()
        revertTask = nil
        revertAt = nil
    }

    private func doRevert() async {
        revertAt = nil
        let client = SamsungArtClient(host: tvIP, savedToken: savedToken)
        client.onRawMessage = { [weak self] raw in
            let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            Task { @MainActor [weak self] in self?.tvLog.append("[\(ts)] \(raw)") }
        }
        do {
            sendStatus = "Resuming art rotation…"
            try await client.checkReachable()
            try await client.connect()
            if !client.token.isEmpty { savedToken = client.token }
            let idsToDelete = deleteOnRevert ? uploadedContentIds : []
            try await client.revertToSamsungArt(deleteIds: idsToDelete)
            client.disconnect()
            if deleteOnRevert { uploadedContentIds = [] }
            sendStatus = "Art rotation resumed ✓"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if sendStatus == "Art rotation resumed ✓" { sendStatus = "" }
        } catch {
            sendStatus = ""
            errorMessage = "Revert failed: \(error.localizedDescription)"
            client.disconnect()
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var showSettings = false
    @State private var showGallery  = false
    @FocusState private var promptFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    imageCard
                    promptSection
                    actionButtons
                    statusSection
                    if vm.showDebugLog && !vm.tvLog.isEmpty {
                        debugLogSection
                    }
                }
                .padding()
            }
            .navigationTitle("Nanoframe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showGallery = true } label: {
                        Image(systemName: "photo.on.rectangle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(vm)
            }
            .sheet(isPresented: $showGallery) {
                NavigationStack {
                    GalleryView().environmentObject(vm)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Done") { showGallery = false }
                            }
                        }
                }
            }
        }
    }

    // MARK: Image Card

    @ViewBuilder
    private var imageCard: some View {
        Group {
            if let img = vm.generatedImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(16/9, contentMode: .fit)
                    .cornerRadius(12)
                    .shadow(radius: 6)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "tv")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("Generated image will appear here")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }

        // Save + revert controls
        if vm.generatedImage != nil {
            HStack(spacing: 12) {
                // Save to Photos
                Button {
                    Task { await vm.saveToPhotos(vm.generatedImage!) }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)

                Spacer()

                // Revert countdown / Keep on TV
                if let at = vm.revertAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        let mins = max(0, Int(at.timeIntervalSinceNow / 60) + 1)
                        Text("Reverts in ~\(mins) min")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button("Keep") { vm.keepOnTV() }
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    Button("Revert Now") { vm.revertNow() }
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: Prompt Input

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prompt")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                TextField("A misty mountain at dawn, watercolour…", text: $vm.prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .focused($promptFocused)
                    .submitLabel(.done)
                    .onSubmit { promptFocused = false }

                if !vm.prompt.isEmpty {
                    Button { vm.prompt = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    // MARK: Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                promptFocused = false
                Task { await vm.generate() }
            } label: {
                Label("Generate", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.prompt.trimmingCharacters(in: .whitespaces).isEmpty || vm.phase.isWorking)

            Button {
                Task { await vm.sendToTV() }
            } label: {
                Label("Send to TV", systemImage: "tv")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(vm.phase != .ready || vm.tvIP.isEmpty)
            .tint(vm.phase == .ready ? .green : nil)
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusSection: some View {
        if vm.phase.isWorking {
            VStack(spacing: 8) {
                ProgressView(vm.sendStatus.isEmpty ? vm.phase.label : vm.sendStatus)
                    .progressViewStyle(.linear)
                if vm.phase == .sending && vm.uploadProgress > 0 {
                    ProgressView(value: vm.uploadProgress)
                        .tint(.green)
                }
            }
            .padding(.horizontal, 4)
        } else if let err = vm.errorMessage {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(err).font(.callout).foregroundStyle(.red)
                Spacer()
                Button("Dismiss") { vm.errorMessage = nil }
                    .font(.caption)
            }
            .padding(12)
            .background(Color.red.opacity(0.08))
            .cornerRadius(8)
        } else if !vm.sendStatus.isEmpty {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(vm.sendStatus).font(.callout)
            }
        }
    }

    // MARK: Debug Log

    private var debugLogSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("TV Debug Log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    UIPasteboard.general.string = vm.tvLog.joined(separator: "\n")
                }
                .font(.caption)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.tvLog, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 160)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private let revertOptions = [5, 10, 15, 30, 60]

    var body: some View {
        NavigationStack {
            Form {
                // TV
                Section {
                    HStack {
                        Text("TV IP Address")
                        Spacer()
                        TextField("e.g. 192.168.0.24", text: Binding(
                            get: { vm.tvIP },
                            set: { vm.tvIP = $0 }
                        ))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    }
                } header: {
                    Text("Samsung Frame TV")
                } footer: {
                    Text("Find it on the TV: Settings → General → Network → IP Settings")
                }

                // Provider
                Section("Image Provider") {
                    Picker("Provider", selection: Binding(
                        get: { vm.provider },
                        set: { vm.provider = $0 }
                    )) {
                        ForEach(ImageProvider.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.menu)

                    if vm.provider == .openAI {
                        SecureField("OpenAI key (sk-…)", text: Binding(
                            get: { vm.apiKey }, set: { vm.apiKey = $0 }
                        ))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    }
                    if vm.provider == .nanoBanana {
                        SecureField("Nano Banana API key", text: Binding(
                            get: { vm.nbKey }, set: { vm.nbKey = $0 }
                        ))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    }
                    if vm.provider == .pollinations {
                        Label("No API key required", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                }

                // Auto-revert
                Section {
                    Toggle("Auto-revert to art rotation", isOn: Binding(
                        get: { vm.autoRevert }, set: { vm.autoRevert = $0 }
                    ))
                    if vm.autoRevert {
                        Picker("Revert after", selection: Binding(
                            get: { vm.revertMinutes }, set: { vm.revertMinutes = $0 }
                        )) {
                            ForEach(revertOptions, id: \.self) { m in
                                Text(m < 60 ? "\(m) min" : "1 hour").tag(m)
                            }
                        }
                        .pickerStyle(.menu)
                        Toggle("Delete Nanoframe images on revert", isOn: Binding(
                            get: { vm.deleteOnRevert }, set: { vm.deleteOnRevert = $0 }
                        ))
                    }
                } header: {
                    Text("Art Rotation")
                } footer: {
                    Text("When enabled, Samsung's art slideshow resumes automatically after your image has been shown.")
                }

                // Debug
                Section {
                    Toggle("Show TV debug log", isOn: Binding(
                        get: { vm.showDebugLog }, set: { vm.showDebugLog = $0 }
                    ))
                } header: {
                    Text("Debug")
                }

                // Siri
                Section {
                    Label("\"Show [description] on the Frame TV\"", systemImage: "mic.fill")
                        .font(.callout)
                    Text("Add this phrase in the Shortcuts app, or ask Siri: \"Show a sunset on the Frame TV using Nanoframe\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Siri Shortcut")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
