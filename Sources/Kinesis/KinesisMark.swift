import SwiftUI

struct KinesisMark: View {
    var size = CGSize(width: 38, height: 36)
    var lineWidth = 3.24
    private static let links: [Path] = [-15.0, 0, 15].map { offset in
        let angle = 32.0 * .pi / 180
        let points = (0..<24).map { index in
            let t = Double(index) / 24 * 2 * .pi
            let x = 15 * cos(t), y = 30 * sin(t)
            return CGPoint(x: 50 + offset + x * cos(angle) - y * sin(angle),
                           y: 50 + x * sin(angle) + y * cos(angle))
        }
        var path = Path()
        path.move(to: points[0])
        for index in points.indices {
            let a = points[(index + 23) % 24], b = points[index]
            let c = points[(index + 1) % 24], d = points[(index + 2) % 24]
            path.addCurve(to: c,
                          control1: CGPoint(x: b.x + (c.x - a.x) / 6, y: b.y + (c.y - a.y) / 6),
                          control2: CGPoint(x: c.x - (d.x - b.x) / 6, y: c.y - (d.y - b.y) / 6))
        }
        path.closeSubpath()
        return path
    }
    private static let linkBounds = links.reduce(CGRect.null) { $0.union($1.boundingRect) }

    var body: some View {
        let lineWidth = lineWidth
        let bounds = Self.linkBounds.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        return Canvas { context, size in
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            context.translateBy(x: (size.width - bounds.width * scale) / 2,
                                y: (size.height - bounds.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.drawLayer { layer in
                for path in Self.links {
                    // Clear the crossing underneath each link without painting a background.
                    layer.blendMode = .destinationOut
                    layer.stroke(path, with: .color(.black), lineWidth: lineWidth * 1.7)
                    layer.blendMode = .normal
                    layer.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }.frame(width: size.width, height: size.height).accessibilityHidden(true)
    }
}
