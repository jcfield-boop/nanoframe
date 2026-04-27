import SwiftUI

// MARK: - Gallery grid

struct GalleryView: View {
    @EnvironmentObject var vm: AppViewModel
    @ObservedObject private var store = ImageStore.shared
    @State private var selected: GalleryItem?
    @State private var deleteTarget: GalleryItem?
    @State private var confirmDelete = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        Group {
            if store.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No saved images yet")
                        .font(.headline)
                    Text("Images you generate and send to the TV will appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(store.items) { item in
                            GalleryCell(item: item, store: store)
                                .onTapGesture { selected = item }
                                .contextMenu {
                                    Button {
                                        Task { await resend(item) }
                                    } label: {
                                        Label("Send to TV", systemImage: "tv")
                                    }
                                    Button(role: .destructive) {
                                        deleteTarget = item
                                        confirmDelete = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { item in
            ImageDetailView(item: item, store: store)
                .environmentObject(vm)
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

    private func resend(_ item: GalleryItem) async {
        if !item.contentId.isEmpty {
            await vm.selectOnTV(contentId: item.contentId)
            return
        }
        guard let jpeg = store.image(for: item)?.jpegData(compressionQuality: 0.95) else { return }
        vm.prompt = item.prompt
        vm.generatedImage = store.image(for: item)
        vm.imageData = jpeg
        vm.phase = .ready
    }

    private func deleteFromTV(_ item: GalleryItem) async {
        let tvIP = vm.tvIP
        guard !tvIP.isEmpty, !item.contentId.isEmpty else {
            store.delete(item); return
        }
        let client = SamsungArtClient(host: tvIP, savedToken: vm.savedToken)
        try? await client.checkReachable()
        try? await client.connect()
        try? await client.revertToSamsungArt(deleteIds: [item.contentId])
        client.disconnect()
        store.delete(item)
        vm.uploadedContentIds.removeAll { $0 == item.contentId }
    }
}

// MARK: - Thumbnail cell

struct GalleryCell: View {
    let item: GalleryItem
    let store: ImageStore

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let img = store.image(for: item) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                } else {
                    Rectangle().fill(Color(.secondarySystemBackground))
                        .aspectRatio(16/9, contentMode: .fill)
                }
            }
            .clipped()
            .cornerRadius(8)

            // Prompt overlay
            LinearGradient(colors: [.clear, .black.opacity(0.6)],
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

// MARK: - Detail view

struct ImageDetailView: View {
    let item: GalleryItem
    let store: ImageStore
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var status = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let img = store.image(for: item) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(16/9, contentMode: .fit)
                            .cornerRadius(12)
                            .shadow(radius: 4)
                    }

                    Text(item.prompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(item.date.formatted(date: .long, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !status.isEmpty {
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(spacing: 12) {
                        Button {
                            Task { await sendToTV() }
                        } label: {
                            Label("Send to TV", systemImage: "tv")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            Task { await saveToPhotos() }
                        } label: {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle("Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func sendToTV() async {
        dismiss()
        if !item.contentId.isEmpty {
            await vm.selectOnTV(contentId: item.contentId)
            return
        }
        guard let jpeg = store.image(for: item)?.jpegData(compressionQuality: 0.95) else { return }
        vm.prompt = item.prompt
        vm.generatedImage = store.image(for: item)
        vm.imageData = jpeg
        vm.phase = .ready
        await vm.sendToTV()
    }

    private func saveToPhotos() async {
        guard let img = store.image(for: item) else { return }
        await vm.saveToPhotos(img)
        status = "Saved to Photos ✓"
    }
}
