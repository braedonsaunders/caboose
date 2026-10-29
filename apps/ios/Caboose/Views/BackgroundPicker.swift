import CabooseKit
import PhotosUI
import SwiftUI

/// Chooses the background of the app and the computer's desktop at once: the brand gradient,
/// wallpapers that change every quarter hour, one wallpaper, or the owner's own picture.
struct BackgroundPicker: View {
    @Environment(AppModel.self) private var model
    @State private var picked: PhotosPickerItem?
    @State private var failure: String?
    private let store = WallpaperStore.shared
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LazyVGrid(columns: columns, spacing: 12) {
                    option("Gradient", selected: store.choice == .gradient) {
                        Backdrop()
                    } action: { store.choose(.gradient) }
                    option("Rotating", selected: store.choice == .rotating) {
                        thumbnail(store.current.flatMap { $0.isPhotograph ? $0 : nil } ?? Wallpaper.library[0])
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption.weight(.bold))
                                    .padding(6)
                                    .glassEffect(.regular, in: .circle)
                                    .padding(6)
                            }
                    } action: { store.choose(.rotating) }
                    PhotosPicker(selection: $picked, matching: .images) {
                        tile("Your Photo", selected: store.choice == .custom) {
                            if store.choice == .custom, let image = store.image {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                ZStack {
                                    Backdrop()
                                    Image(systemName: "photo.badge.plus").font(.title)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Photographs").font(.title3.weight(.bold))
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Wallpaper.library) { wallpaper in
                            option(wallpaper.name, selected: store.choice == .photo(wallpaper.id)) {
                                thumbnail(wallpaper)
                            } action: { store.choose(.photo(wallpaper.id)) }
                        }
                    }
                    Text("Photographs from Unsplash, through Lorem Picsum.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Generated Scenes").font(.title3.weight(.bold))
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Wallpaper.generated) { wallpaper in
                            option(wallpaper.name, selected: store.choice == .photo(wallpaper.id)) {
                                thumbnail(wallpaper)
                            } action: { store.choose(.photo(wallpaper.id)) }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background { ShellBackground() }
        .navigationTitle("Wallpaper")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    try await store.useCustom(data)
                } catch {
                    failure = error.localizedDescription
                }
                picked = nil
            }
        }
        .alert("Couldn't Use This Photo", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    private func option(_ title: String, selected: Bool, @ViewBuilder preview: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) { tile(title, selected: selected, preview: preview) }
            .buttonStyle(.plain)
    }

    private func tile(_ title: String, selected: Bool, @ViewBuilder preview: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(3 / 2, contentMode: .fit)
                .overlay { preview() }
                .clipShape(.rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(selected ? Brand.amber : .white.opacity(0.15), lineWidth: selected ? 3 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Brand.amber)
                            .padding(6)
                    }
                }
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func thumbnail(_ wallpaper: Wallpaper) -> some View {
        WallpaperThumbnail(wallpaper: wallpaper)
    }
}

/// A cached preview of one photograph or generated scene.
private struct WallpaperThumbnail: View {
    let wallpaper: Wallpaper
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Backdrop()
            if let image {
                Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
            }
        }
        .task(id: wallpaper.id) {
            let drawn = await WallpaperStore.shared.thumbnail(wallpaper, size: CGSize(width: 450, height: 300))
            withAnimation(.easeInOut(duration: 0.25)) { image = drawn }
        }
    }
}
