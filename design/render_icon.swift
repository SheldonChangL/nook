// Nook 的 app icon。用 CoreGraphics 直接畫，不依賴任何設計工具。
import Foundation
import ImageIO

let blueTop = CGColor(red: 38 / 255, green: 126 / 255, blue: 190 / 255, alpha: 1)
let blueBottom = CGColor(red: 5 / 255, green: 46 / 255, blue: 78 / 255, alpha: 1)
let frameWhite = CGColor(red: 232 / 255, green: 245 / 255, blue: 255 / 255, alpha: 1)
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
    // Nook 是私密的小角落：用拱門與鎖孔，而不是保險箱轉盤。
    // 後者在 Dock 的小尺寸下會讀成風扇。
    let outerW = plate.width * 0.56, outerH = plate.height * 0.62
    let outer = CGRect(x: plate.midX - outerW / 2, y: plate.midY - outerH * 0.43, width: outerW, height: outerH)
    let frame = CGPath(roundedRect: outer, cornerWidth: outerW * 0.28, cornerHeight: outerW * 0.28, transform: nil)
    ctx.setFillColor(frameWhite); ctx.addPath(frame); ctx.fillPath()
    let innerInset = outerW * 0.105, inner = outer.insetBy(dx: innerInset, dy: innerInset)
    let door = CGPath(roundedRect: inner, cornerWidth: inner.width * 0.28, cornerHeight: inner.width * 0.28, transform: nil)
    ctx.setFillColor(blueBottom); ctx.addPath(door); ctx.fillPath()
    ctx.setStrokeColor(CGColor(red: 143 / 255, green: 210 / 255, blue: 1, alpha: 0.65)); ctx.setLineWidth(max(size * 0.011, 1)); ctx.addPath(door); ctx.strokePath()
    let keyCenter = CGPoint(x: inner.midX, y: inner.midY - inner.height * 0.04)
    let keyCircle = CGRect(x: keyCenter.x - inner.width * 0.13, y: keyCenter.y - inner.width * 0.13, width: inner.width * 0.26, height: inner.width * 0.26)
    ctx.setFillColor(white); ctx.fillEllipse(in: keyCircle)
    ctx.setFillColor(white); ctx.addPath(roundedRect(CGRect(x: keyCenter.x - inner.width * 0.045, y: keyCenter.y, width: inner.width * 0.09, height: inner.height * 0.20), radius: inner.width * 0.045)); ctx.fillPath()
    ctx.setFillColor(blueBottom); ctx.fillEllipse(in: CGRect(x: keyCenter.x - inner.width * 0.035, y: keyCenter.y - inner.width * 0.035, width: inner.width * 0.07, height: inner.width * 0.07))
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
