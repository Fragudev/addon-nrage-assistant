import Foundation
import CoreGraphics
import ImageIO

// Usage:
//   swift make_tga.swift <input.png> <output.tga> <size> <marginFraction>
//     Centres the image, keeping its aspect ratio, on a transparent size x size canvas.
//   swift make_tga.swift <input.png> <output.tga> <width>x<height> stretch
//     Stretches the image edge to edge over a width x height canvas, with no margins and no letterbox.
// Both write a 32-bit uncompressed TGA (bottom-left origin, straight alpha), the format WoW loads for textures.
let args = CommandLine.arguments
let usage = "usage: make_tga <in.png> <out.tga> <size> <margin>\n"
    + "       make_tga <in.png> <out.tga> <width>x<height> stretch\n"

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

guard args.count == 5 else { fail(usage, code: 2) }

// The canvas size: a square from the centred usage, or width x height from the stretch usage.
let width: Int
let height: Int
let stretch = args[3].contains("x")
if stretch {
    let parts = args[3].split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0, args[4] == "stretch" else { fail(usage, code: 2) }
    width = parts[0]
    height = parts[1]
} else {
    guard let size = Int(args[3]), Double(args[4]) != nil else { fail(usage, code: 2) }
    width = size
    height = size
}

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot read \(args[1])", code: 1)
}

let rect: CGRect
let summary: String
if stretch {
    rect = CGRect(x: 0, y: 0, width: width, height: height)
    summary = "image stretched to fill the canvas"
} else {
    // Square canvas: keep the aspect ratio inside the margins.
    let margin = Double(args[4]) ?? 0
    let available = Double(width) * (1.0 - 2.0 * margin)
    let scale = min(available / Double(image.width), available / Double(image.height))
    let drawWidth = Double(image.width) * scale
    let drawHeight = Double(image.height) * scale
    rect = CGRect(
        x: (Double(width) - drawWidth) / 2.0, y: (Double(height) - drawHeight) / 2.0,
        width: drawWidth, height: drawHeight
    )
    summary = "logo drawn at \(Int(drawWidth))x\(Int(drawHeight))"
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

context.clear(CGRect(x: 0, y: 0, width: width, height: height))
context.interpolationQuality = .high
context.draw(image, in: rect)

guard let data = context.data else { exit(1) }
let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

// TGA header: no id, no colour map, type 2 (uncompressed true colour), 32 bpp, 8 alpha bits.
var out = Data([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0])
out.append(contentsOf: [UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8), 32, 8])

// CGContext memory is top row first; a bottom-left-origin TGA wants the bottom row first.
for row in stride(from: height - 1, through: 0, by: -1) {
    for column in 0..<width {
        let offset = (row * width + column) * 4
        let alpha = Int(pixels[offset + 3])
        var red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
        if alpha > 0 && alpha < 255 {
            // Undo the premultiplication: TGA stores straight alpha.
            red = min(255, red * 255 / alpha)
            green = min(255, green * 255 / alpha)
            blue = min(255, blue * 255 / alpha)
        }
        out.append(contentsOf: [UInt8(blue), UInt8(green), UInt8(red), UInt8(alpha)])
    }
}

try out.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]): \(width)x\(height), \(out.count) bytes; \(summary)")
