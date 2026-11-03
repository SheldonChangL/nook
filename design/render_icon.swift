// SecureManage 的 app icon。用 CoreGraphics 直接畫，不依賴任何設計工具。
//
// 跑法：
//   swift design/render_icon.swift design/out
//
// 會產出 1024 的主檔，其餘尺寸用 sips 從主檔縮（見 design/build_icons.sh）。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 色票（跟 app 的 seed #3F6E8C 同一家族）

let navyTop = CGColor(red: 0.267, green: 0.447, blue: 0.561, alpha: 1) // #44728F
let navyBottom = CGColor(red: 0.133, green: 0.247, blue: 0.325, alpha: 1) // #223F53
let shieldFill = CGColor(red: 0.961, green: 0.973, blue: 0.980, alpha: 1) // #F5F8FA
let keyholeColor = CGColor(red: 0.149, green: 0.278, blue: 0.365, alpha: 1) // #26475D

// MARK: - 形狀

/// Apple 風格的連續圓角方形（超橢圓）。用參數式取樣，比圓角矩形更接近系統 icon。
func squirclePath(in rect: CGRect, n: Double = 5.0, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = Double(rect.width) / 2
    let b = Double(rect.height) / 2
    let cx = Double(rect.midX)
    let cy = Double(rect.midY)
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * Double.pi
        let ct = cos(t)
        let st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2.0 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2.0 / n), st)
        if i == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

/// 盾牌。上緣平、兩側內收、底部收成一個圓潤的尖。
/// rect 是盾牌的外接框。
func shieldPath(in rect: CGRect) -> CGPath {
    let w = rect.width
    let h = rect.height
    let x = rect.minX
    let y = rect.minY // CoreGraphics 原點在左下，y 往上長

    let top = y + h
    let bottom = y
    let left = x
    let right = x + w

    let path = CGMutablePath()
    // 從左上角開始，順著上緣到右上角
    path.move(to: CGPoint(x: left, y: top - h * 0.06))
    path.addQuadCurve(
        to: CGPoint(x: right, y: top - h * 0.06),
        control: CGPoint(x: x + w * 0.5, y: top + h * 0.045))
    // 右側往下，先直後收
    path.addLine(to: CGPoint(x: right, y: bottom + h * 0.42))
    // 右下收向底部的尖
    path.addCurve(
        to: CGPoint(x: x + w * 0.5, y: bottom),
        control1: CGPoint(x: right, y: bottom + h * 0.20),
        control2: CGPoint(x: x + w * 0.74, y: bottom + h * 0.055))
    // 左下對稱回來
    path.addCurve(
        to: CGPoint(x: left, y: bottom + h * 0.42),
        control1: CGPoint(x: x + w * 0.26, y: bottom + h * 0.055),
        control2: CGPoint(x: left, y: bottom + h * 0.20))
    path.closeSubpath()
    return path
}

/// 鑰匙孔的圓。
func keyholeCircle(center: CGPoint, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: center, radius: r, startAngle: 0, endAngle: 2 * .pi,
                clockwise: false)
    return path
}

/// 鑰匙孔的槽。上窄下寬，底部平 —— 往下收窄會看起來像麥克風。
///
/// 槽的頂端要伸進圓裡面才接得起來。圓和槽分兩次填，不要併成同一個 path：
/// 兩個子路徑的繞行方向相反時，nonzero 填充會把重疊處挖掉，接縫會露出白邊。
func keyholeSlot(center: CGPoint, radius r: CGFloat) -> CGPath {
    let slotTop = center.y + r * 0.30 // 伸進圓內
    let slotBottom = center.y - r * 2.55
    let topHalf = r * 0.40
    let bottomHalf = r * 0.76

    let slot = CGMutablePath()
    slot.move(to: CGPoint(x: center.x - topHalf, y: slotTop))
    slot.addLine(to: CGPoint(x: center.x + topHalf, y: slotTop))
    slot.addLine(to: CGPoint(x: center.x + bottomHalf, y: slotBottom + r * 0.10))
    slot.addQuadCurve(
        to: CGPoint(x: center.x + bottomHalf * 0.78, y: slotBottom),
        control: CGPoint(x: center.x + bottomHalf, y: slotBottom))
    slot.addLine(to: CGPoint(x: center.x - bottomHalf * 0.78, y: slotBottom))
    slot.addQuadCurve(
        to: CGPoint(x: center.x - bottomHalf, y: slotBottom + r * 0.10),
        control: CGPoint(x: center.x - bottomHalf, y: slotBottom))
    slot.closeSubpath()
    return slot
}

// MARK: - 繪製

func renderIcon(size: CGFloat) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // macOS 的 icon 不是整張填滿，四周要留白給陰影。
    let inset = size * 0.0957
    let plate = CGRect(x: inset, y: inset,
                       width: size - inset * 2, height: size - inset * 2)

    // 底板陰影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.028,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.setFillColor(navyBottom)
    ctx.addPath(squirclePath(in: plate))
    ctx.fillPath()
    ctx.restoreGState()

    // 底板漸層。macOS icon 慣例會帶一點由上而下的微漸層，不是裝飾而是讓它有實體感。
    ctx.saveGState()
    ctx.addPath(squirclePath(in: plate))
    ctx.clip()
    if let gradient = CGGradient(
        colorsSpace: cs,
        colors: [navyTop, navyBottom] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.minY),
            options: [])
    }
    ctx.restoreGState()

    // 盾牌
    let shieldWidth = plate.width * 0.505
    let shieldHeight = shieldWidth * 1.18
    let shield = CGRect(
        x: plate.midX - shieldWidth / 2,
        y: plate.midY - shieldHeight / 2 - plate.height * 0.012,
        width: shieldWidth,
        height: shieldHeight)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.006),
                  blur: size * 0.018,
                  color: CGColor(red: 0.04, green: 0.10, blue: 0.15, alpha: 0.35))
    ctx.setFillColor(shieldFill)
    ctx.addPath(shieldPath(in: shield))
    ctx.fillPath()
    ctx.restoreGState()

    // 鑰匙孔挖在盾牌上
    let keyR = shieldWidth * 0.138
    let keyCenter = CGPoint(x: shield.midX, y: shield.midY + shieldHeight * 0.145)
    ctx.setFillColor(keyholeColor)
    ctx.addPath(keyholeCircle(center: keyCenter, radius: keyR))
    ctx.fillPath()
    ctx.addPath(keyholeSlot(center: keyCenter, radius: keyR))
    ctx.fillPath()

    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("寫不出 \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - 進入點

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "design/out")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// 每個尺寸各自重畫，而不是從大圖縮，小尺寸的線條才不會糊掉。
for size in [16, 32, 64, 128, 256, 512, 1024] {
    guard let image = renderIcon(size: CGFloat(size)) else {
        FileHandle.standardError.write("畫不出 \(size)\n".data(using: .utf8)!)
        exit(1)
    }
    write(image, to: outDir.appendingPathComponent("app_icon_\(size).png"))
    print("app_icon_\(size).png")
}
