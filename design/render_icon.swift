// Nook 的 app icon。用 CoreGraphics 直接畫，不依賴任何設計工具。
import Foundation
import ImageIO

let blueTop = CGColor(red: 47 / 255, green: 142 / 255, blue: 219 / 255, alpha: 1)
let blueBottom = CGColor(red: 13 / 255, green: 92 / 255, blue: 150 / 255, alpha: 1)
let doorWhite = CGColor(red: 245 / 255, green: 248 / 255, blue: 250 / 255, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

func squirclePath(in rect: CGRect, n: Double = 5, steps: Int = 720) -> CGPath {
    let path = CGMutablePath(), a = Double(rect.width) / 2, b = Double(rect.height) / 2
    let cx = Double(rect.midX), cy = Double(rect.midY)
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * Double.pi
        let x = cx + a * copysign(pow(abs(cos(t)), 2 / n), cos(t))
        let y = cy + b * copysign(pow(abs(sin(t)), 2 / n), sin(t))
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath(); return path
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func renderIcon(size: CGFloat) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true); ctx.interpolationQuality = .high
    let inset = size * 0.0957
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.028, color: CGColor(gray: 0, alpha: 0.28)); ctx.setFillColor(blueBottom); ctx.addPath(squirclePath(in: plate)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(squirclePath(in: plate)); ctx.clip()
    let gradient = CGGradient(colorsSpace: cs, colors: [blueTop, blueBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.minY), options: []); ctx.restoreGState()
    let doorW = plate.width * 0.56, door = CGRect(x: plate.midX - doorW / 2, y: plate.midY - doorW / 2, width: doorW, height: doorW)
    let dial = CGRect(x: door.midX - doorW * 0.26, y: door.midY - doorW * 0.26, width: doorW * 0.52, height: doorW * 0.52)
    let handle = CGRect(x: door.maxX - doorW * 0.115, y: door.midY - doorW * 0.105, width: doorW * 0.06, height: doorW * 0.21)
    let cutout = CGMutablePath(); cutout.addPath(roundedRect(door, radius: doorW * 0.12)); cutout.addEllipse(in: dial); cutout.addPath(roundedRect(handle, radius: handle.width / 2))
    ctx.setFillColor(doorWhite); ctx.addPath(cutout); ctx.drawPath(using: .eoFill)
    let center = CGPoint(x: dial.midX, y: dial.midY), tickRadius = dial.width * 0.39, tickLength = max(size * 0.035, dial.width * 0.13)
    ctx.setStrokeColor(white); ctx.setLineWidth(max(size * 0.025, 1.3)); ctx.setLineCap(.round)
    for i in 0..<8 { let a = CGFloat(i) * .pi / 4; let dx = cos(a), dy = sin(a); ctx.move(to: CGPoint(x: center.x + dx * (tickRadius - tickLength), y: center.y + dy * (tickRadius - tickLength))); ctx.addLine(to: CGPoint(x: center.x + dx * tickRadius, y: center.y + dy * tickRadius)); ctx.strokePath() }
    ctx.setFillColor(white); ctx.fillEllipse(in: CGRect(x: center.x - doorW * 0.065, y: center.y - doorW * 0.065, width: doorW * 0.13, height: doorW * 0.13))
    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
}

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "out")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for pixelSize in [16, 32, 64, 128, 256, 512, 1024] {
    guard let image = renderIcon(size: CGFloat(pixelSize)) else { exit(1) }
    write(image, to: outDir.appendingPathComponent("app_icon_\(pixelSize).png"))
    print("app_icon_\(pixelSize).png")
}
