import SwiftUI

// MARK: - ViewModel

@MainActor
class AppViewModel: ObservableObject {
    @Published var prompt = ""
    @Published var generatedImage: NSImage?
    @Published var imageData: Data?
    @Published var phase: Phase = .idle
    @Published var errorMessage: String?
    @Published var sendStatus: String = ""
    @Published var uploadProgress: Double = 0
    @Published var tvLog: [String] = []
    @Published var remoteBanner: String?
    @Published var revertAt: Date? = nil

    /// Content IDs uploaded by Nanoframe, persisted so revert works across app restarts.
    var uploadedContentIds: [String] {
        get { UserDefaults.standard.stringArray(forKey: "nanoframe_content_ids") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "nanoframe_content_ids") }
    }

    private var lastContentId: String? = nil
    private var revertTask: Task<Void, Never>?

    enum Phase: Equatable {
        case idle, generating, ready, sending, done
        var isWorking: Bool { self == .generating || self == .sending }
        var label: String {
            switch self {
            case .idle:       return "Enter a prompt to begin"
            case .generating: return "Generating with DALL·E 3…"
            case .ready:      return "Image ready — send to TV?"
            case .sending:    return "Uploading to Frame TV…"
            case .done:       return "Now displaying on Frame TV"
            }
        }
        var dot: Color {
            switch self {
            case .idle:       return .gray
            case .generating: return .yellow
            case .ready:      return .blue
            case .sending:    return .orange
            case .done:       return .green
            }
        }
    }

    // @Published so SwiftUI re-renders when picker/toggle values change.
    // didSet syncs back to UserDefaults for persistence across launches.

    @Published var provider: ImageProvider = {
        ImageProvider(rawValue: UserDefaults.standard.string(forKey: "image_provider") ?? "") ?? .pollinations
    }() { didSet { UserDefaults.standard.set(provider.rawValue, forKey: "image_provider") } }

    @Published var showDebugLog: Bool = {
        UserDefaults.standard.object(forKey: "show_debug_log") == nil
            ? false : UserDefaults.standard.bool(forKey: "show_debug_log")
    }() { didSet { UserDefaults.standard.set(showDebugLog, forKey: "show_debug_log") } }

    @Published var autoRevert: Bool = {
        UserDefaults.standard.object(forKey: "auto_revert") == nil
            ? true : UserDefaults.standard.bool(forKey: "auto_revert")
    }() { didSet { UserDefaults.standard.set(autoRevert, forKey: "auto_revert") } }

    @Published var revertMinutes: Int = {
        let v = UserDefaults.standard.integer(forKey: "revert_minutes"); return v == 0 ? 10 : v
    }() { didSet { UserDefaults.standard.set(revertMinutes, forKey: "revert_minutes") } }

    @Published var deleteOnRevert: Bool = {
        UserDefaults.standard.object(forKey: "delete_on_revert") == nil
            ? false : UserDefaults.standard.bool(forKey: "delete_on_revert")
    }() { didSet { UserDefaults.standard.set(deleteOnRevert, forKey: "delete_on_revert") } }
    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "openai_api_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "openai_api_key") }
    }
    var nbKey: String {
        get { UserDefaults.standard.string(forKey: "nb_api_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "nb_api_key") }
    }
    var tvIP: String {
        get { UserDefaults.standard.string(forKey: "tv_ip") ?? "192.168.0.24" }
        set { UserDefaults.standard.set(newValue, forKey: "tv_ip") }
    }
    var savedToken: String {
        get { UserDefaults.standard.string(forKey: "samsung_tv_token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "samsung_tv_token") }
    }

    private let svc = DallEService()

    // MARK: Actions

    var activeKey: String {
        switch provider {
        case .pollinations: return "free"
        case .nanoBanana:   return nbKey
        case .gptImage1:    return apiKey
        case .openAI:       return apiKey
        }
    }

    func generate() async {
        cancelRevert()   // new generation cancels any pending revert
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
        cancelRevert()   // cancel any previous revert before starting new send
        phase = .sending
        sendStatus = "Upscaling to 4K…"
        uploadProgress = 0
        errorMessage = nil
        do {
            let upscaled = svc.upscaleTo4K(data) ?? data
            let sizeMB = String(format: "%.1f", Double(upscaled.count) / 1_048_576)

            sendStatus = "Checking TV is reachable…"
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

            try await client.checkReachable()

            sendStatus = "Connecting to Frame TV…"
            try await client.connect()
            if !client.token.isEmpty { savedToken = client.token }

            sendStatus = "Uploading \(sizeMB) MB…"
            let contentId = try await client.uploadAndDisplay(upscaled)
            if !contentId.isEmpty {
                lastContentId = contentId
                uploadedContentIds = (uploadedContentIds + [contentId])
            }

            // Save to gallery
            let savedItem = ImageStore.shared.add(jpeg: data, prompt: prompt, contentId: contentId)
            if !contentId.isEmpty {
                ImageStore.shared.setContentId(contentId, for: savedItem.id)
            }

            uploadProgress = 1
            phase = .done
            sendStatus = "Displayed on Frame TV ✓"
            // Schedule revert to Samsung Art rotation
            if autoRevert {
                scheduleRevert(seconds: revertMinutes * 60)
            }
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
            lastContentId = contentId
            if !uploadedContentIds.contains(contentId) {
                uploadedContentIds.append(contentId)
            }
            phase = .done
            sendStatus = "Displayed on Frame TV ✓"
            if autoRevert { scheduleRevert(seconds: revertMinutes * 60) }
            try await Task.sleep(nanoseconds: 4_000_000_000)
            if phase == .done { phase = .ready; sendStatus = "" }
        } catch {
            errorMessage = "TV error: \(error.localizedDescription)"
            sendStatus = ""
            phase = .ready
        }
    }

    // MARK: - Art Rotation Revert

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
        let task = Task { [weak self] in
            guard let self else { return }
            await self.doRevert()
        }
        revertTask = task
    }

    func cancelRevert() {
        revertTask?.cancel()
        revertTask = nil
        revertAt = nil
    }

    func keepOnTV() {
        cancelRevert()
        sendStatus = "Keeping on TV — revert cancelled"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if sendStatus == "Keeping on TV — revert cancelled" { sendStatus = "" }
        }
    }

    private func doRevert() async {
        revertAt = nil
        let client = SamsungArtClient(host: tvIP, savedToken: savedToken)
        client.onRawMessage = { [weak self] raw in
            let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            Task { @MainActor [weak self] in
                self?.tvLog.append("[\(ts)] \(raw)")
            }
        }
        do {
            sendStatus = "Checking TV is reachable…"
            try await client.checkReachable()
            sendStatus = "Connecting to Frame TV…"
            try await client.connect()
            if !client.token.isEmpty { savedToken = client.token }
            let idsToDelete = deleteOnRevert ? uploadedContentIds : []
            sendStatus = deleteOnRevert ? "Removing Nanoframe images…" : "Resuming art rotation…"
            try await client.revertToSamsungArt(deleteIds: idsToDelete)
            client.disconnect()
            if deleteOnRevert { uploadedContentIds = []; lastContentId = nil }
            sendStatus = "Art rotation resumed ✓"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if sendStatus == "Art rotation resumed ✓" { sendStatus = "" }
        } catch {
            sendStatus = ""
            errorMessage = "Revert failed: \(error.localizedDescription)"
            client.disconnect()
        }
    }

    /// Called by RemoteTriggerServer when Lango sends a prompt
    func generateAndSend(prompt: String) async {
        self.prompt = prompt
        remoteBanner = "⚡ Triggered by Lango: \"\(prompt)\""
        defer { remoteBanner = nil }
        await generate()
        guard phase == .ready else { return }
        await sendToTV()
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @State private var showSettings = false
    @State private var showHelp     = false
    @State private var showGallery  = false
    @State private var server: RemoteTriggerServer?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 270, maxWidth: 310)
            VSplitView {
                canvas
                if vm.showDebugLog && !vm.tvLog.isEmpty {
                    tvLogPanel
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: $showSettings) { SettingsView(vm: vm) }
        .sheet(isPresented: $showHelp)     { HelpView() }
        .sheet(isPresented: $showGallery)  { GalleryView(vm: vm) }
        .alert("Error", isPresented: Binding(get: { vm.errorMessage != nil },
                                             set: { if !$0 { vm.errorMessage = nil } })) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .onAppear {
            startServer()
            // Bring window to front when launched from the terminal
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { server?.stop() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            VStack(alignment: .leading, spacing: 2) {
                Text("Nanoframe").font(.title2.bold())
                Text("\(vm.provider.displayName) → Frame TV")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding([.top, .horizontal])
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    // Remote banner
                    if let banner = vm.remoteBanner {
                        Label(banner, systemImage: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.indigo.opacity(0.85))
                            .cornerRadius(6)
                    }

                    // Prompt
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Prompt", systemImage: "text.bubble").font(.headline)
                        TextEditor(text: $vm.prompt)
                            .font(.body)
                            .frame(minHeight: 110, maxHeight: 180)
                            .scrollContentBackground(.hidden)
                            .background(Color(.textBackgroundColor).opacity(0.6))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1))

                        if vm.activeKey.isEmpty {
                            Label("Add your \(vm.provider == .nanoBanana ? "Nano Banana" : "OpenAI") key in Settings",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Button {
                            Task { await vm.generate() }
                        } label: {
                            Label(vm.phase == .generating ? "Generating…" : "Generate",
                                  systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(vm.phase.isWorking || vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.activeKey.isEmpty)
                    }

                    Divider()

                    // Send to TV
                    VStack(spacing: 8) {
                        Button {
                            Task { await vm.sendToTV() }
                        } label: {
                            Label(vm.phase == .sending ? "Uploading…" : "Send to Frame TV",
                                  systemImage: "tv")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(vm.phase.isWorking || vm.imageData == nil)

                        if vm.phase == .sending {
                            VStack(alignment: .leading, spacing: 4) {
                                if vm.uploadProgress > 0 && vm.uploadProgress < 1 {
                                    ProgressView(value: vm.uploadProgress)
                                        .progressViewStyle(.linear)
                                } else {
                                    ProgressView()
                                        .progressViewStyle(.linear)
                                }
                                if !vm.sendStatus.isEmpty {
                                    Text(vm.sendStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }

                        HStack(spacing: 4) {
                            Text("TV must be in Art/Frame Mode.")
                                .font(.caption2).foregroundStyle(.secondary)
                            Button {
                                showHelp = true
                            } label: {
                                Text("Help")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }

                        // Revert countdown
                        if let at = vm.revertAt {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                TimelineView(.periodic(from: .now, by: 30)) { _ in
                                    let mins = max(0, Int(at.timeIntervalSinceNow / 60) + 1)
                                    Text("Reverts in ~\(mins) min")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Keep") { vm.keepOnTV() }
                                    .font(.caption2)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.green)
                                Button("Revert Now") { vm.revertNow() }
                                    .font(.caption2)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .padding()
            }

            Spacer(minLength: 0)
            Divider()

            // Status bar
            HStack(spacing: 6) {
                Circle().fill(vm.phase.dot).frame(width: 7, height: 7)
                Text(vm.phase.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let img = vm.generatedImage {
                    Button {
                        let pb = NSPasteboard.general; pb.clearContents(); pb.writeObjects([img])
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Copy image to clipboard")

                    Button {
                        if let jpeg = img.jpegData {
                            ImageStore.shared.saveToFile(jpeg, prompt: vm.prompt)
                        }
                    } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Save image to file…")
                }
                Button { showGallery  = true } label: { Image(systemName: "photo.on.rectangle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Gallery")
                Button { showHelp     = true } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Help")
                Button { showSettings = true } label: { Image(systemName: "gear") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.controlBackgroundColor))
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if vm.phase == .generating {
                VStack(spacing: 14) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(1.6).tint(.white)
                    Text("Generating…").foregroundStyle(.white.opacity(0.6))
                }
            } else if let image = vm.generatedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity.animation(.easeIn(duration: 0.3)))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 80))
                        .foregroundStyle(.white.opacity(0.1))
                    Text("Generated art appears here")
                        .foregroundStyle(.white.opacity(0.25))
                        .font(.callout)
                }
            }

            // Done overlay
            if vm.phase == .done {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Now displaying on Frame TV").foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.75)).cornerRadius(10)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(minWidth: 560)
    }

    // MARK: - TV Log Panel

    private var tvLogPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TV WebSocket Log").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(vm.tvLog.joined(separator: "\n"), forType: .string)
                }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Clear") { vm.tvLog = [] }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(.windowBackgroundColor))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.tvLog.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.green)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .id(i)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: vm.tvLog.count) { _, _ in
                    proxy.scrollTo(vm.tvLog.count - 1, anchor: .bottom)
                }
            }
            .background(Color.black)
            .frame(minHeight: 120, maxHeight: 200)
        }
    }

    // MARK: - Trigger server

    private func startServer() {
        let s = RemoteTriggerServer { [weak vm] prompt in
            guard let vm else { return }
            Task { await vm.generateAndSend(prompt: prompt) }
        }
        s.start()
        server = s
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var provider:       Binding<ImageProvider> { Binding(get: { vm.provider       }, set: { vm.provider       = $0 }) }
    var nbKey:          Binding<String>        { Binding(get: { vm.nbKey          }, set: { vm.nbKey          = $0 }) }
    var apiKey:         Binding<String>        { Binding(get: { vm.apiKey         }, set: { vm.apiKey         = $0 }) }
    var tvIP:           Binding<String>        { Binding(get: { vm.tvIP           }, set: { vm.tvIP           = $0 }) }
    var autoRevert:     Binding<Bool>          { Binding(get: { vm.autoRevert     }, set: { vm.autoRevert     = $0 }) }
    var revertMinutes:  Binding<Int>           { Binding(get: { vm.revertMinutes  }, set: { vm.revertMinutes  = $0 }) }
    var deleteOnRevert: Binding<Bool>          { Binding(get: { vm.deleteOnRevert }, set: { vm.deleteOnRevert = $0 }) }
    var showDebugLog:   Binding<Bool>          { Binding(get: { vm.showDebugLog   }, set: { vm.showDebugLog   = $0 }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.title2.bold())

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Provider", selection: provider) {
                        ForEach(ImageProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch vm.provider {
                    case .pollinations:
                        Label("No API key required — just generate!", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    case .nanoBanana:
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nano Banana API Key").font(.caption).foregroundStyle(.secondary)
                            SecureField("nb_…", text: nbKey).textFieldStyle(.roundedBorder)
                            Link("Get a key → nanobanana.expert",
                                 destination: URL(string: "https://nanobanana.expert")!)
                                .font(.caption2)
                        }
                    case .gptImage1:
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OpenAI API Key").font(.caption).foregroundStyle(.secondary)
                            SecureField("sk-…", text: apiKey).textFieldStyle(.roundedBorder)
                            Text("Native 1536×1024 landscape · returns b64 · quality: high")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    case .openAI:
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OpenAI API Key").font(.caption).foregroundStyle(.secondary)
                            SecureField("sk-…", text: apiKey).textFieldStyle(.roundedBorder)
                            Text("DALL·E 3 · 1792×1024 upscaled to 4K")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(4)
            } label: { Label("Image Generation", systemImage: "wand.and.stars") }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TV IP Address").font(.caption).foregroundStyle(.secondary)
                        TextField("192.168.0.24", text: tvIP).textFieldStyle(.roundedBorder)
                    }
                    Divider()
                    Toggle(isOn: autoRevert) {
                        Text("Auto-revert to art rotation").font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    if vm.autoRevert {
                        HStack {
                            Text("Revert after").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: revertMinutes) {
                                Text("5 min").tag(5)
                                Text("10 min").tag(10)
                                Text("15 min").tag(15)
                                Text("30 min").tag(30)
                                Text("1 hour").tag(60)
                            }
                            .labelsHidden()
                            .frame(width: 90)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Toggle(isOn: deleteOnRevert) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Delete AI images on revert").font(.caption)
                            Text("Off = keep in My Photos as a gallery")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Toggle(isOn: showDebugLog) {
                        Text("Show TV debug log panel").font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Text("Lango trigger server: 0.0.0.0:11436")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(4)
            } label: { Label("Samsung Frame TV", systemImage: "tv") }

            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent) }
        }
        .padding(24)
        .frame(width: 420)
    }
}
