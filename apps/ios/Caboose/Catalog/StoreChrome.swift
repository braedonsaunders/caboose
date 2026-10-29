import ImageIO
import SwiftUI
import UIKit

// The storefront pieces the app Library and the MCP Library share: an icon's rounded well,
// a row of tiles under its title with See All, a tile, and a list row.

/// A picture from an icon's bytes, decoded once at most 128 pixels on a side: a small file can
/// name huge dimensions.
func storeIconImage(_ data: Data) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 128,
              kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
}

enum StoreIconSize {
    /// A storefront tile's.
    case tile
    /// A list row's.
    case row
    /// A detail page's header.
    case large
}

/// An icon in its rounded well, or a stand-in when there is no picture.
struct StoreIcon<Placeholder: View>: View {
    let image: UIImage?
    var size: StoreIconSize = .row
    @ViewBuilder let placeholder: () -> Placeholder

    /// The well's side, its corner radius, and the picture's inset.
    private var metrics: (side: CGFloat, corner: CGFloat, inset: CGFloat) {
        switch size {
        case .tile: (88, 20, 8)
        case .row: (44, 10, 4)
        case .large: (96, 22, 8)
        }
    }

    var body: some View {
        let (side, corner, inset) = metrics
        ZStack {
            RoundedRectangle(cornerRadius: corner).fill(.quaternary)
            if let image { Image(uiImage: image).resizable().scaledToFit().padding(inset) }
            else { placeholder().foregroundStyle(.secondary) }
        }
        .frame(width: side, height: side)
    }
}

/// One row of a storefront: its title, what its order means, See All, and its tiles.
struct StoreShelf<Item: Identifiable, Tile: View>: View {
    let title: String
    var note: String? = nil
    /// What See All pushes onto the navigation stack.
    let seeAll: String
    let items: [Item]
    @ViewBuilder let tile: (Item) -> Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.title3.weight(.semibold))
                    Spacer()
                    NavigationLink("See All", value: seeAll)
                }
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { tile($0) }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// An entry in a row: its icon, name and what it is, then its action. With `open`, the icon
/// and text open the entry's details.
struct StoreTile<Icon: View, Action: View>: View {
    let name: String
    let summary: String
    var open: (() -> Void)? = nil
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let open {
                Button(action: open) { face }.buttonStyle(.plain).accessibilityHint("Shows details")
            } else {
                face
            }
            action().padding(.top, 2)
        }
        .frame(width: 112, alignment: .leading)
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 6) {
            icon()
            Text(name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }
        .contentShape(.rect)
    }
}

/// An entry in a list: its icon, name, what it is and any details, then its controls. With
/// `open`, the icon and text open the entry's details.
struct StoreListRow<Icon: View, Details: View, Trailing: View>: View {
    let name: String
    let summary: String
    var open: (() -> Void)? = nil
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let details: () -> Details
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let open {
                Button(action: open) { face.frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.borderless).foregroundStyle(.primary).accessibilityHint("Shows details")
            } else {
                face
                Spacer()
            }
            trailing()
        }
    }

    private var face: some View {
        HStack(spacing: 12) {
            icon()
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.medium))
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                details()
            }
        }
        .contentShape(.rect)
    }
}
