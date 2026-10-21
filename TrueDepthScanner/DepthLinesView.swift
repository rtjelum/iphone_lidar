import SwiftUI

/// Draws depth as horizontal lines connecting the raw depth points; lines bend upward where things are closer.
/// Lines are drawn top to bottom and each one blacks out the area under it,
/// so lower lines hide the ones "behind" them, which gives a 3D relief look.
/// Where the sensor has no reading, the line has a gap.
struct DepthLinesView: View {
    let lines: DepthLines
    /// Height of a line at full nearness, measured in line spacings.
    let relief: Double
    /// Line width as a fraction of the spacing between lines.
    let thickness: Double
    /// Typical rise (0...1) of the top and bottom lines. Used to spread the lines so the
    /// top line sits at the top edge and the bottom line at the bottom edge, with no empty bands.
    var topRise: Double = 0
    var bottomRise: Double = 0
    /// .fill crops the edges to cover the space; .fit shows the whole picture with black bars.
    var contentMode: ContentMode = .fill

    /// Grayscale: far = dim gray, near = white.
    private static let gradient = Gradient(colors: [Color(white: 0.35), Color(white: 1.0)])

    var body: some View {
        Canvas { context, size in
            let rows = lines.rows
            let cols = lines.cols
            let unit = size.height / CGFloat(rows)
            let amplitude = unit * CGFloat(relief)
            // Lines rise by nearness × amplitude. Shift and spread their resting positions so the
            // typical top line lands at the top edge and the typical bottom line at the bottom edge.
            let topOffset = CGFloat(topRise) * amplitude
            let spacing = max(unit * 0.3, (size.height + CGFloat(bottomRise - topRise) * amplitude) / CGFloat(rows))
            let lineWidth = max(0.5, unit * CGFloat(thickness))
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

            for r in 0..<rows {
                let baseY = topOffset + (CGFloat(r) + 0.5) * spacing
                // Shade by height above the line's resting position: gray = far, white = near.
                let shading = GraphicsContext.Shading.linearGradient(
                    Self.gradient,
                    startPoint: CGPoint(x: 0, y: baseY),
                    endPoint: CGPoint(x: 0, y: baseY - amplitude))

                var segment: [CGPoint] = []
                func drawSegment() {
                    defer { segment.removeAll(keepingCapacity: true) }
                    guard segment.count >= 2, let first = segment.first, let last = segment.last else { return }
                    var line = Path()
                    line.addLines(segment)

                    // Hide whatever earlier (higher) lines drew underneath this one.
                    var cover = line
                    cover.addLine(to: CGPoint(x: last.x, y: baseY + lineWidth / 2))
                    cover.addLine(to: CGPoint(x: first.x, y: baseY + lineWidth / 2))
                    cover.closeSubpath()
                    context.fill(cover, with: .color(.black))
                    context.stroke(line, with: shading, style: style)
                }

                for c in 0..<cols {
                    let value = lines.nearness[r * cols + c]
                    if value.isNaN {
                        drawSegment()
                        continue
                    }
                    let x = CGFloat(c) / CGFloat(cols - 1) * size.width
                    segment.append(CGPoint(x: x, y: baseY - CGFloat(value) * amplitude))
                }
                drawSegment()
            }
        }
        // Keep the camera's shape. With .fill the parent crops the edges.
        .aspectRatio(lines.aspect, contentMode: contentMode)
        .drawingGroup()
    }
}
