import SwiftUI

/// A round tile with a glyph: a host, an artist, an album.
struct IconTile: View {
    let systemImage: String
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45))
            .foregroundStyle(Palette.onSurface)
            .frame(width: size, height: size)
            .background(Palette.secondaryContainer, in: .circle)
            .accessibilityHidden(true)
    }
}
