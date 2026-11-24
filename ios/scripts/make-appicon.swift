// Builds ios/Kero/Assets.xcassets/AppIcon.appiconset/AppIcon.png from Kero's
// official icon (resources/icon.png): the macOS icon is a squircle on a
// transparent margin, while iOS masks a full-bleed square itself. This crops
// to the squircle's opaque bounds and fills the corners with the icon's own
// background, giving an opaque 1024×1024 square.
//
//   swift ios/scripts/make-appicon.swift resources/icon.png ios/Kero/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fputs("usage: make-appicon <icon.png> <out.png> [--inspect]\n", stderr); exit(1)
}
let w = image.width, h = image.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
func at(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) { let i = (y * w + x) * 4; return (px[i], px[i+1], px[i+2], px[i+3]) }
// Opaque bounds (alpha > 250) along the centre row and column.
var minX = w, maxX = 0, minY = h, maxY = 0
for x in 0..<w where at(x, h / 2).3 > 250 { minX = min(minX, x); maxX = max(maxX, x) }
for y in 0..<h where at(w / 2, y).3 > 250 { minY = min(minY, y); maxY = max(maxY, y) }
let bg = at(minX + 40, h / 2)
print("opaque x \(minX)...\(maxX) y \(minY)...\(maxY) bg \(bg)")
if args.contains("--inspect") { exit(0) }
let side = max(maxX - minX, maxY - minY) + 1
let crop = image.cropping(to: CGRect(x: minX, y: minY, width: side, height: side))!
let out = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
out.setFillColor(CGColor(srgbRed: CGFloat(bg.0) / 255, green: CGFloat(bg.1) / 255, blue: CGFloat(bg.2) / 255, alpha: 1))
out.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
out.interpolationQuality = .high
out.draw(crop, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(args[2])")
