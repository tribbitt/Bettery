#!/usr/bin/env swift
// Generates the .iconset directory used by `iconutil -c icns` to build the
// app's Finder/Dock icon. Crops the source PNG to its opaque bounds (kills
// transparent padding around the battery), then re-centers it on a square
// canvas with ~10% breathing room so the design doesn't get clipped by the
// Liquid Glass / Squircle masking macOS applies to app icons.
//
// Usage: swift make_icns.swift <input.png> <iconset_output_dir>

import AppKit

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make_icns.swift <input.png> <iconset_dir>\n".utf8))
    exit(2)
}
let inputPath = CommandLine.arguments[1]
let iconsetDir = CommandLine.arguments[2]

guard let img = NSImage(contentsOfFile: inputPath),
      let cg  = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("failed to load \(inputPath)\n".utf8))
    exit(1)
}

// Find the bounding box of non-transparent pixels — same algorithm as
// AppDelegate.trimTransparentEdges, kept here standalone so the build script
// doesn't need to compile the app before generating the icon.
let w = cg.width, h = cg.height
let bpp = 4, bpr = w * bpp
var pixels = [UInt8](repeating: 0, count: w * h * bpp)
let cs = CGColorSpaceCreateDeviceRGB()
guard let scan = CGContext(data: &pixels, width: w, height: h,
                           bitsPerComponent: 8, bytesPerRow: bpr, space: cs,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
scan.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w where pixels[y*bpr + x*bpp + 3] > 5 {
        if x < minX { minX = x }
        if y < minY { minY = y }
        if x > maxX { maxX = x }
        if y > maxY { maxY = y }
    }
}
guard maxX >= minX, maxY >= minY,
      let cropped = cg.cropping(to: CGRect(x: minX, y: minY,
                                           width: maxX-minX+1, height: maxY-minY+1))
else { exit(1) }

// Pad to a square canvas. 10% padding total (5% each side) so the content
// stays clear of the rounded-square mask macOS applies to dock/Finder icons.
let cw = cropped.width, ch = cropped.height
let largest = max(cw, ch)
let canvas = Int(Double(largest) * 1.10)
let yPad = (canvas - ch) / 2
let xPad = (canvas - cw) / 2

func render(to size: Int) -> Data? {
    guard let outCtx = CGContext(data: nil, width: size, height: size,
                                 bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    outCtx.interpolationQuality = .high
    let scale = Double(size) / Double(canvas)
    let dst = CGRect(x: Double(xPad) * scale, y: Double(yPad) * scale,
                     width: Double(cw) * scale, height: Double(ch) * scale)
    outCtx.draw(cropped, in: dst)
    guard let outCG = outCtx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: outCG).representation(using: .png, properties: [:])
}

// (Pixel size, filename suffix). macOS expects all ten of these to satisfy
// every retina/non-retina pairing iconutil understands.
let variants: [(Int, String)] = [
    (16,   "16x16"),     (32,   "16x16@2x"),
    (32,   "32x32"),     (64,   "32x32@2x"),
    (128,  "128x128"),   (256,  "128x128@2x"),
    (256,  "256x256"),   (512,  "256x256@2x"),
    (512,  "512x512"),   (1024, "512x512@2x"),
]

try? FileManager.default.removeItem(atPath: iconsetDir)
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
for (px, name) in variants {
    guard let data = render(to: px) else { continue }
    try? data.write(to: URL(fileURLWithPath: "\(iconsetDir)/icon_\(name).png"))
}
