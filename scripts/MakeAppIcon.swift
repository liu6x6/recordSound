#!/usr/bin/env swift
// 生成 VoiceScribe App 图标：渐变圆角背景 + 白色波形 + 录音红点
// 用法: swift scripts/MakeAppIcon.swift <输出目录>

import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Resources"

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

    let s = size
    // 圆角背景（macOS 图标圆角比例 ≈ 18.5%）
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.185, cornerHeight: s * 0.185, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // 垂直渐变：靛蓝 → 紫
    let colors = [
        CGColor(red: 0.31, green: 0.27, blue: 0.90, alpha: 1),
        CGColor(red: 0.58, green: 0.20, blue: 0.92, alpha: 1),
    ]
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: s),
                           end: CGPoint(x: s * 0.6, y: 0),
                           options: [])

    // 白色波形条（7 根，中间高两侧低）
    let heights: [CGFloat] = [0.16, 0.30, 0.46, 0.62, 0.46, 0.30, 0.16]
    let barW = s * 0.055
    let gap = s * 0.045
    let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = (s - totalW) / 2
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    for h in heights {
        let barH = s * h
        let barRect = CGRect(x: x, y: (s - barH) / 2 + s * 0.04, width: barW, height: barH)
        let barPath = CGPath(roundedRect: barRect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
        ctx.addPath(barPath)
        ctx.fillPath()
        x += barW + gap
    }

    // 右上角录音红点
    let dotR = s * 0.09
    let dotRect = CGRect(x: s * 0.72 - dotR, y: s * 0.72 - dotR, width: dotR * 2, height: dotR * 2)
    ctx.setFillColor(CGColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1))
    ctx.fillEllipse(in: dotRect)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    ctx.fillEllipse(in: dotRect.insetBy(dx: dotR * 0.45, dy: dotR * 0.45))

    image.unlockFocus()
    return image
}

// 生成 iconset
let iconsetDir = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let entries: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in entries {
    let img = drawIcon(size: CGFloat(px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: iconsetDir.appendingPathComponent(name))
}
print("iconset 已生成: \(iconsetDir.path)")
print("接下来运行: iconutil -c icns \(iconsetDir.path) -o \(outDir)/AppIcon.icns")
