// Nook 的 app icon。用 CoreGraphics 直接畫，不依賴任何設計工具。
import Foundation
import ImageIO

// 色票取自 design/nook_icon_mockups.svg 的 01「The Nook」。
let blueTop = CGColor(red: 57 / 255, green: 127 / 255, blue: 192 / 255, alpha: 1)
let blueBottom = CGColor(red: 6 / 255, green: 45 / 255, blue: 78 / 255, alpha: 1)
let frameWhite = CGColor(red: 234 / 255, green: 246 / 255, blue: 255 / 255, alpha: 1)
let keyhole = CGColor(red: 10 / 255, green: 53 / 255, blue: 88 / 255, alpha: 1)
let highlight = CGColor(red: 141 / 255, green: 219 / 255, blue: 252 / 255, alpha: 0.8)

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
    // 01「The Nook」：一道有遮蔽感的拱門變成鎖頭。造型照 mockup 的 240×240 座標畫，
    // 把它縮放到色板上；CoreGraphics 的 y 軸朝上，所以同時上下翻轉。
    ctx.saveGState()
    let unit = plate.width / 240
    ctx.translateBy(x: plate.minX, y: plate.maxY)
    ctx.scaleBy(x: unit, y: -unit)
    // 鎖環：粗的拱形線，兩端圓頭。
    let shackle = CGMutablePath()
    shackle.move(to: CGPoint(x: 61, y: 178))
    shackle.addLine(to: CGPoint(x: 61, y: 114))
    shackle.addCurve(to: CGPoint(x: 120, y: 52), control1: CGPoint(x: 61, y: 78), control2: CGPoint(x: 87, y: 52))
    shackle.addCurve(to: CGPoint(x: 179, y: 114), control1: CGPoint(x: 153, y: 52), control2: CGPoint(x: 179, y: 78))
    shackle.addLine(to: CGPoint(x: 179, y: 178))
    ctx.setStrokeColor(frameWhite); ctx.setLineWidth(22); ctx.setLineCap(.round)
    ctx.addPath(shackle); ctx.strokePath()
    // 鎖身：寬的圓角方塊。
    ctx.setFillColor(frameWhite)
    ctx.addPath(roundedRect(CGRect(x: 48, y: 107, width: 144, height: 91), radius: 23)); ctx.fillPath()
    // 鑰匙孔：圓加一截直柄。
    ctx.setFillColor(keyhole)
    ctx.fillEllipse(in: CGRect(x: 105, y: 132, width: 30, height: 30))
    ctx.fill(CGRect(x: 112, y: 158, width: 16, height: 19))
    // 鎖環左上一道細細的受光邊。
    let shine = CGMutablePath()
    shine.move(to: CGPoint(x: 70, y: 93))
    shine.addCurve(to: CGPoint(x: 120, y: 47), control1: CGPoint(x: 82, y: 63), control2: CGPoint(x: 106, y: 47))
    ctx.setStrokeColor(highlight); ctx.setLineWidth(4); ctx.addPath(shine); ctx.strokePath()
    ctx.restoreGState()
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
for pixelSize in [16, 24, 32, 48, 64, 128, 256, 512, 1024] {
    guard let image = renderIcon(size: CGFloat(pixelSize)) else { exit(1) }
    write(image, to: outDir.appendingPathComponent("app_icon_\(pixelSize).png"))
    print("app_icon_\(pixelSize).png")
}
