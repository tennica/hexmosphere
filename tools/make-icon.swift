// SPDX-License-Identifier: Apache-2.0
// Draws Hexmosphere's app icon into Sources/Hexmosphere/Assets.xcassets/AppIcon.appiconset:
// an H3 cell and its six neighbours in rainbow colours inside a circle, on the
// map's ocean blue. Green is in the middle and the other six run round the ring
// in rainbow order (red, orange, yellow, then blue, indigo, violet), clockwise
// from the upper left.
//
//   swiftc -module-cache-path build/mc tools/make-icon.swift -o build/make-icon && build/make-icon
//
// iOS gets one opaque 1024-pixel square (the system rounds the corners); the Mac
// gets each size it asks for, as a rounded square on a transparent margin, the
// shape macOS icons share.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Sources/Hexmosphere/Assets.xcassets/AppIcon.appiconset")
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, a])!
}

/// Pointy-top hexagon: corners at 90°, 150°, …
func hexagon(_ centre: CGPoint, _ radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for k in 0..<6 {
        let angle = CGFloat.pi / 180 * (90 + 60 * CGFloat(k))
        let point = CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        k == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

/// The artwork on a 1024-unit square, y up.
func drawArtwork(_ ctx: CGContext) {
    let gradient = CGGradient(colorsSpace: sRGB, colors: [colour(0.10, 0.22, 0.36), colour(0.04, 0.11, 0.20)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024), end: .zero, options: [])

    let centre = CGPoint(x: 512, y: 512)
    let cell: CGFloat = 150                  // grid cell circumradius
    let drawn = cell * 0.90                  // each hexagon, leaving gaps
    let step = 3.0.squareRoot() * cell       // between neighbour centres
    let red = colour(0.92, 0.25, 0.24), orange = colour(1.00, 0.58, 0.12), yellow = colour(0.98, 0.84, 0.20),
        green = colour(0.27, 0.78, 0.38), blue = colour(0.26, 0.58, 1.00), indigo = colour(0.38, 0.35, 0.88),
        violet = colour(0.70, 0.38, 0.92)
    // Ring cells k = 0…5 sit at 0°, 60°, … anticlockwise from the right.
    let ring = [yellow, orange, red, violet, indigo, blue]
    var cells = [(centre, green)]
    for k in 0..<6 {
        let angle = CGFloat.pi / 180 * 60 * CGFloat(k)
        cells.append((CGPoint(x: centre.x + step * cos(angle), y: centre.y + step * sin(angle)), ring[k]))
    }
    let outline = colour(1, 1, 1, 0.45), lineWidth: CGFloat = 6
    for (point, fill) in cells {
        ctx.addPath(hexagon(point, drawn))
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.addPath(hexagon(point, drawn))
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(lineWidth)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    // The circle through the outermost corners, 12 units clear of them
    // (outline edge to outline edge).
    var reach: CGFloat = 0
    for (point, _) in cells {
        for k in 0..<6 {
            let angle = CGFloat.pi / 180 * (90 + 60 * CGFloat(k))
            reach = max(reach, hypot(point.x + drawn * cos(angle) - centre.x, point.y + drawn * sin(angle) - centre.y))
        }
    }
    reach += lineWidth / 2 + lineWidth / 2 + 12
    ctx.addEllipse(in: CGRect(x: centre.x - reach, y: centre.y - reach, width: reach * 2, height: reach * 2))
    ctx.setStrokeColor(colour(1, 1, 1, 0.7))
    ctx.setLineWidth(lineWidth)
    ctx.strokePath()
}

func render(_ pixels: Int, mac: Bool) -> CGImage {
    let alpha = mac ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast   // iOS icons must be opaque
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: alpha.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    if mac {
        // macOS icon grid: an 824-unit rounded square centred on the 1024 canvas.
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
        ctx.clip()
        ctx.translateBy(x: 100, y: 100)
        ctx.scaleBy(x: 824 / 1024, y: 824 / 1024)
    }
    drawArtwork(ctx)
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,
                                                      UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var images: [[String: String]] = []
write(render(1024, mac: false), "ios-1024.png")
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"])
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "mac-\(points)@\(scale)x.png"
        write(render(points * scale, mac: true), name)
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: folder.appendingPathComponent("Contents.json"))
let catalog = folder.deletingLastPathComponent().appendingPathComponent("Contents.json")
if !FileManager.default.fileExists(atPath: catalog.path) {
    try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted])
        .write(to: catalog)
}
print("wrote \(images.count) icon images to \(folder.path)")
