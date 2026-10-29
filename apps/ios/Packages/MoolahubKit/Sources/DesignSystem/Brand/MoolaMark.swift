import SwiftUI

/// The MoolaHub mark: an open savings ring, a rising line and a goal star,
/// drawn from the web logo's paths (`Logo.tsx`). The frame is the 160-unit
/// square x 16…176, y 27…187, which fits the whole ring (the web's
/// 30 30 150 150 viewBox clips its left edge).
/// Ring and line are jade in light mode and white in dark mode; the star is
/// always jade-500 (`Palette.markJade`).
public struct MoolaMark: View {
    public enum Tone: Sendable {
        /// Jade on light, white ring on dark (follows the color scheme).
        case automatic
        /// White ring for dark surfaces.
        case light
    }

    let size: CGFloat
    let tone: Tone

    public init(size: CGFloat = 64, tone: Tone = .automatic) {
        self.size = size
        self.tone = tone
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 160
            let transform = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -16, y: -27)
            let ringColor: Color = tone == .light ? .white : Color(uiColor: PaletteUIColor.markRing)
            let starColor = Color(uiColor: PaletteUIColor.markJade)
            let stroke = StrokeStyle(lineWidth: 12 * scale, lineCap: .round, lineJoin: .round)

            for path in Self.strokedPaths {
                context.stroke(path.applying(transform), with: .color(ringColor), style: stroke)
            }
            context.fill(Self.star.applying(transform), with: .color(starColor))
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("MoolaHub")
        .accessibilityAddTraits(.isImage)
        .accessibilityIgnoresInvertColors(true)
    }

    // Geometry in the logo's own coordinates.
    private static let ringCenter = CGPoint(x: 96, y: 113)
    private static let ringRadius: CGFloat = 72

    private static func arc(from start: CGPoint, to end: CGPoint) -> Path {
        // SVG arcs with sweep-flag 1 run in the direction of increasing angle.
        let startAngle = atan2(start.y - ringCenter.y, start.x - ringCenter.x)
        var endAngle = atan2(end.y - ringCenter.y, end.x - ringCenter.x)
        while endAngle <= startAngle { endAngle += 2 * .pi }
        var path = Path()
        path.addRelativeArc(
            center: ringCenter,
            radius: ringRadius,
            startAngle: .radians(startAngle),
            delta: .radians(endAngle - startAngle)
        )
        return path
    }

    private static let strokedPaths: [Path] = {
        let left = arc(from: CGPoint(x: 56.786, y: 173.384), to: CGPoint(x: 122.972, y: 46.243))
        let right = arc(from: CGPoint(x: 154.249, y: 70.679), to: CGPoint(x: 135.214, y: 173.384))
        var line = Path()
        line.addLines([
            CGPoint(x: 52, y: 151), CGPoint(x: 78, y: 113), CGPoint(x: 99, y: 133),
            CGPoint(x: 123, y: 82), CGPoint(x: 142, y: 116),
        ])
        return [left, right, line]
    }()

    private static let star: Path = {
        var path = Path()
        path.addLines([
            CGPoint(x: 156.328, y: 56.263), CGPoint(x: 144.174, y: 60.110), CGPoint(x: 140.328, y: 72.263),
            CGPoint(x: 136.481, y: 60.110), CGPoint(x: 124.328, y: 56.263), CGPoint(x: 136.481, y: 52.417),
            CGPoint(x: 140.328, y: 40.263), CGPoint(x: 144.174, y: 52.417),
        ])
        path.closeSubpath()
        return path
    }()
}

/// The horizontal wordmark (mark + "MoolaHub"), from the web's brand SVGs,
/// with light and dark variants in the asset catalog.
public struct Wordmark: View {
    let height: CGFloat

    public init(height: CGFloat = 32) {
        self.height = height
    }

    public var body: some View {
        Image("Wordmark", bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel("MoolaHub")
            .accessibilityIgnoresInvertColors(true)
    }
}

#Preview("Mark and wordmark") {
    VStack(spacing: 24) {
        MoolaMark(size: 96)
        Wordmark(height: 40)
        MoolaMark(size: 64, tone: .light)
            .padding()
            .background(Palette.ctaBackground)
    }
    .padding()
    .moolaCanvas()
}
