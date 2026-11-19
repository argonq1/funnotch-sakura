import ImageIO
import SwiftUI

enum NotchPalette {
    static let accent = Color(red: 0.52, green: 0.89, blue: 0.86)
    static let panel = Color(white: 0.075)
    static let secondaryText = Color.white.opacity(0.62)
    static let rim = LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.05)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
    static let selection = LinearGradient(colors: [.white, Color(red: 0.89, green: 0.77, blue: 0.82)],
                                          startPoint: .top, endPoint: .bottom)
}

enum SakuraTheme {
    static let accent = Color(red: 0.95, green: 0.71, blue: 0.81)
    static let panel = Color(red: 0.107, green: 0.067, blue: 0.087)
    static let base = Color(red: 0.049, green: 0.032, blue: 0.041)
    static let selectedTab = Color(red: 0.31, green: 0.22, blue: 0.26)
}

/// A single small bundled photo, shared by every notch window.
struct SakuraBlossoms: View {
    let width: CGFloat
    let height: CGFloat
    var opacity = 0.72

    private static let photo: CGImage? = {
        guard let url = Bundle.main.url(forResource: "SakuraBlossoms", withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }()

    var body: some View {
        if let photo = Self.photo {
            Image(decorative: photo, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height, alignment: .topTrailing)
                .clipped()
                .saturation(0.72)
                .overlay {
                    LinearGradient(colors: [SakuraTheme.panel.opacity(0.18), .black.opacity(0.58)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.44), location: 0.22),
                        .init(color: .black, location: 0.66),
                    ], startPoint: .leading, endPoint: .trailing)
                }
                .opacity(opacity)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

/// Shared native surfaces. Gradients and a fine rim give depth without a
/// backdrop blur, an extra renderer or an always-running animation.
struct NotchSurface: ViewModifier {
    var radius: CGFloat = 16
    var opacity = 0.075
    var tint = SakuraTheme.accent
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(LinearGradient(colors: [.white.opacity(opacity * 1.35), tint.opacity(opacity * 0.4)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(NotchPalette.rim, lineWidth: 0.5).allowsHitTesting(false))
    }
}

struct NotchPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct NotchHoverHighlight: ViewModifier {
    var tint = Color.white
    var radius: CGFloat = 12
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tint.opacity(hovering ? 0.14 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
    }
}

struct NotchReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    private var visible: Bool { revealed || Motion.snapshotMode }
    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : -10)
            .scaleEffect(visible || reduceMotion ? 1 : 0.98, anchor: .top)
            .onAppear {
                if Motion.snapshotMode || reduceMotion { revealed = true }
                else { withAnimation(.easeOut(duration: 0.26).delay(0.045)) { revealed = true } }
            }
    }
}
