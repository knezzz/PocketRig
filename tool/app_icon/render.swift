// Draws app_icon.svg's shapes into every launcher icon file. Run from the repo root:
//   swift tool/app_icon/render.swift
// No SVG renderer is needed: the icon is one stroked path and one circle.
import AppKit

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(colorSpace: srgb, components: [r / 255, g / 255, b / 255, 1])! }
let tile = rgb(0x28, 0x2C, 0x33)
let accent = rgb(0xD9, 0x91, 0x5B)
let black = rgb(0, 0, 0)

enum Ground { case square, rounded(CGFloat), none }  // none: only the mark (adaptive layers)

/// A [px]×[px] PNG: the 512 viewBox is mapped into [box], the ground fills [ground]'s shape of [box].
func render(_ path: String, px: Int, box: CGRect? = nil, ground: Ground, mark: CGColor? = accent, opaque: Bool = false, shadow: Bool = false) {
  let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
    space: srgb, bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
  let s = CGFloat(px)
  let b = box ?? CGRect(x: 0, y: 0, width: s, height: s)
  ctx.setShouldAntialias(true)
  ctx.setFillColor(tile)
  switch ground {
  case .square: ctx.fill(b)
  case .rounded(let r):
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.009), blur: s * 0.02, color: CGColor(gray: 0, alpha: 0.3)) }
    ctx.addPath(CGPath(roundedRect: b, cornerWidth: b.width * r, cornerHeight: b.width * r, transform: nil)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0)
  case .none: break
  }
  if let m = mark {
    ctx.translateBy(x: b.minX, y: b.minY)
    ctx.scaleBy(x: b.width / 512, y: b.height / 512)
    ctx.translateBy(x: 0, y: 512); ctx.scaleBy(x: 1, y: -1)  // viewBox y runs down
    ctx.setStrokeColor(m); ctx.setFillColor(m)
    ctx.setLineWidth(36); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 204, y: 136)); p.addLine(to: CGPoint(x: 372, y: 136)); p.addLine(to: CGPoint(x: 372, y: 300))
    p.addLine(to: CGPoint(x: 256, y: 384)); p.addLine(to: CGPoint(x: 140, y: 300)); p.addLine(to: CGPoint(x: 140, y: 204))
    ctx.addPath(p); ctx.strokePath()
    ctx.fillEllipse(in: CGRect(x: 120, y: 116, width: 48, height: 48))
  }
  let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// iOS: the whole square, no alpha (the system rounds it).
let ios = "ios/Runner/Assets.xcassets/AppIcon.appiconset/"
for (name, px) in [("20x20@1x", 20), ("20x20@2x", 40), ("20x20@3x", 60), ("29x29@1x", 29), ("29x29@2x", 58), ("29x29@3x", 87),
                   ("40x40@1x", 40), ("40x40@2x", 80), ("40x40@3x", 120), ("60x60@2x", 120), ("60x60@3x", 180),
                   ("76x76@1x", 76), ("76x76@2x", 152), ("83.5x83.5@2x", 167), ("1024x1024@1x", 1024)] {
  render(ios + "Icon-App-\(name).png", px: px, ground: .square, opaque: true)
}

// macOS: the usual rounded tile, 100/1024 margin, a soft shadow.
for px in [16, 32, 64, 128, 256, 512, 1024] {
  let s = CGFloat(px), m = s * 100 / 1024
  render("macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_\(px).png", px: px,
    box: CGRect(x: m, y: m, width: s - 2 * m, height: s - 2 * m), ground: .rounded(0.2237), shadow: true)
}

// Android: legacy mipmaps (rounded tile), adaptive layers (108 dp canvas, the 512 view mapped to its middle 72 dp).
let res = "android/app/src/main/res/"
for (dir, scale) in [("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)] as [(String, CGFloat)] {
  render(res + "mipmap-\(dir)/ic_launcher.png", px: Int(48 * scale), ground: .rounded(0.18))
  let px = Int(108 * scale), s = CGFloat(px), inset = s * 18 / 108
  let box = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
  render(res + "mipmap-\(dir)/ic_launcher_foreground.png", px: px, box: box, ground: .none)
  render(res + "mipmap-\(dir)/ic_launcher_monochrome.png", px: px, box: box, ground: .none, mark: black)
}
