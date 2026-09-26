import SwiftUI

/// Clementine's colours: the brand, and the Material 3 roles generated from it, light and dark.
enum Palette {
    static let primary = Color("Primary")
    static let onPrimary = Color("OnPrimary")
    static let primaryContainer = Color("PrimaryContainer")
    static let onPrimaryContainer = Color("OnPrimaryContainer")
    static let secondary = Color("Secondary")
    static let secondaryContainer = Color("SecondaryContainer")
    static let onSecondaryContainer = Color("OnSecondaryContainer")
    static let tertiary = Color("Tertiary")
    static let surface = Color("Surface")
    static let onSurface = Color("OnSurface")
    static let surfaceVariant = Color("SurfaceVariant")
    static let onSurfaceVariant = Color("OnSurfaceVariant")
    static let surfaceContainerLowest = Color("SurfaceContainerLowest")
    static let surfaceContainerLow = Color("SurfaceContainerLow")
    static let surfaceContainer = Color("SurfaceContainer")
    static let surfaceContainerHigh = Color("SurfaceContainerHigh")
    static let surfaceContainerHighest = Color("SurfaceContainerHighest")
    static let outline = Color("Outline")
    static let outlineVariant = Color("OutlineVariant")
    static let error = Color("Error")
    static let errorContainer = Color("ErrorContainer")
    static let onErrorContainer = Color("OnErrorContainer")

    /// The identity orange: the gradient and the mark. Never under white text.
    static let brandOrange = Color("BrandOrange")
    /// The orange for fills under white text.
    static let brandOrangeUI = Color("BrandOrangeUI")
    static let brandPlum = Color("BrandPlum")
    static let onBrand = Color("OnBrand")

    /// The identity gradient, plum to orange, left to right.
    static let brandGradient = LinearGradient(
        colors: [brandPlum, brandOrange], startPoint: .leading, endPoint: .trailing)
}

/// The design system's type scale, in SF Pro, scaled with Dynamic Type.
enum TextStyle {
    case display, headlineMedium, headlineSmall, titleLarge, titleMedium, bodyLarge, bodyMedium, labelLarge, labelMedium

    var size: CGFloat {
        switch self {
        case .display: 36
        case .headlineMedium: 28
        case .headlineSmall: 24
        case .titleLarge: 22
        case .titleMedium, .bodyLarge: 16
        case .bodyMedium, .labelLarge: 14
        case .labelMedium: 12
        }
    }

    var weight: Font.Weight {
        switch self {
        case .display: .bold
        case .titleMedium, .labelLarge, .labelMedium: .medium
        default: .regular
        }
    }

    var relativeTo: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .headlineMedium, .headlineSmall: .title
        case .titleLarge: .title2
        case .titleMedium: .headline
        case .bodyLarge: .body
        case .bodyMedium, .labelLarge: .subheadline
        case .labelMedium: .caption
        }
    }
}

private struct TextStyleModifier: ViewModifier {
    let style: TextStyle
    @ScaledMetric private var size: CGFloat

    init(_ style: TextStyle) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: style.weight))
    }
}

extension View {
    /// Sets the font to one of the design system's styles.
    func textStyle(_ style: TextStyle) -> some View {
        modifier(TextStyleModifier(style))
    }
}

/// The design system's spacing and corners.
enum Metrics {
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24
    static let space8: CGFloat = 32

    /// Artwork, play/pause and sheets.
    static let radiusXL: CGFloat = 28
    /// The mini player.
    static let shapeLarge: CGFloat = 16
    /// Grouped cards.
    static let shapeMedium: CGFloat = 12
    /// Thumbnails and chips.
    static let shapeSmall: CGFloat = 8
}
