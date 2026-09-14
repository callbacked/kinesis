import AppKit
import SwiftUI

@main
struct ExportIcon {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let artwork = ZStack {
            RoundedRectangle(cornerRadius: 196, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 196, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 2))
                .frame(width: 844, height: 844)
                .shadow(color: .black.opacity(0.24), radius: 18, y: 12)
            KinesisMark(size: CGSize(width: 585, height: 550)).foregroundStyle(Color(white: 0.94))
        }.frame(width: 1024, height: 1024)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let renderer = ImageRenderer(content: artwork)
                renderer.scale = Double(size * scale) / 1024
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try png.write(to: destination.appendingPathComponent(name))
            }
        }
    }
}
