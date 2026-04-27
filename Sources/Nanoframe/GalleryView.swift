import SwiftUI

struct GalleryView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject private var store = ImageStore.shared
    @State private var selected: GalleryItem?
    @State private var deleteTarget: GalleryItem?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Gallery").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if store.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("No saved images yet")
                        .font(.headline)
                    Text("Images you generate and send to the TV are saved here automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(store.items) { item in
                            GalleryCell(item: item, store: store)
                                .onTapGesture { selected = item }
                                .contextMenu { contextMenu(for: item) }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 600, minHeight: 460)
        .sheet(item: $selected) { item in
            ImageDetailView(item: item, store: store, vm: vm)
        }
        .confirmationDialog("Delete image?", isPresented: $confirmDelete, presenting: deleteTarget) { item in
            Button("Delete from gallery only", role: .destructive) {
                store.delete(item)
            }
            if !item.contentId.isEmpty {
                Button("Delete from gallery and TV", role: .destructive) {
                    Task { await deleteFromTV(item) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func contextMenu(for item: GalleryItem) -> some View {
        Button("Load into editor") { load(item) }
        Button("Send to TV") { Task { await resend(item) } }
        Divider()
        Button("Save to file…") {
            if let jpeg = store.image(for: item)?.jpegData {
                store.saveToFile(jpeg, prompt: item.prompt)
            }
        }
        Divider()
        Button("Delete…", role: .destructive) {
            deleteTarget = item; confirmDelete = true
        }
    }

    private func load(_ item: GalleryItem) {
        vm.prompt         = item.prompt
        vm.generatedImage = store.image(for: item)
        vm.imageData      = store.image(for: item)?.jpegData
        vm.phase          = .ready
        dismiss()
    }

    private func resend(_ item: GalleryItem) async {
        if !item.contentId.isEmpty {
            await vm.selectOnTV(contentId: item.contentId)
            return
        }
        load(item)
        await vm.sendToTV()
    }

    private func deleteFromTV(_ item: GalleryItem) async {
        guard !item.contentId.isEmpty else { store.delete(item); return }
        let client = SamsungArtClient(host: vm.tvIP, savedToken: vm.savedToken)
        try? await client.checkReachable()
        try? await client.connect()
        try? await client.revertToSamsungArt(deleteIds: [item.contentId])
        client.disconnect()
        store.delete(item)
        vm.uploadedContentIds.removeAll { $0 == item.contentId }
    }
}

// MARK: - Thumbnail

struct GalleryCell: View {
    let item: GalleryItem
    let store: ImageStore

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let img = store.image(for: item) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color(.windowBackgroundColor))
                        .aspectRatio(16/9, contentMode: .fill)
                }
            }
            .clipped()
            .cornerRadius(8)

            LinearGradient(colors: [.clear, .black.opacity(0.65)],
                           startPoint: .center, endPoint: .bottom)
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.prompt)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(item.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(6)
        }
    }
}

// MARK: - Detail sheet

struct ImageDetailView: View {
    let item: GalleryItem
    let store: ImageStore
    @ObservedObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.prompt).font(.headline).lineLimit(2)
                    Text(item.date.formatted(date: .long, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if let img = store.image(for: item) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding()
            }

            Divider()

            HStack(spacing: 12) {
                Button("Load into editor") {
                    vm.prompt         = item.prompt
                    vm.generatedImage = store.image(for: item)
                    vm.imageData      = store.image(for: item)?.jpegData
                    vm.phase          = .ready
                    dismiss()
                }
                Button("Send to TV") {
                    Task {
                        dismiss()
                        if !item.contentId.isEmpty {
                            await vm.selectOnTV(contentId: item.contentId)
                        } else {
                            vm.prompt         = item.prompt
                            vm.generatedImage = store.image(for: item)
                            vm.imageData      = store.image(for: item)?.jpegData
                            vm.phase          = .ready
                            await vm.sendToTV()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Save to file…") {
                    if let jpeg = store.image(for: item)?.jpegData {
                        store.saveToFile(jpeg, prompt: item.prompt)
                    }
                }
                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}

