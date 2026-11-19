import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
// ICNS wraps PNGs in size/scale-specific image records with big-endian lengths.
let renders: [(Int, String)] = [
    (16, "icp4"), (32, "ic11"), (32, "icp5"), (64, "ic12"), (128, "ic07"),
    (256, "ic13"), (256, "ic08"), (512, "ic14"), (512, "ic09"), (1024, "ic10")
]
func sizeBytes(_ count: Int) -> Data {
    var size = UInt32(count).bigEndian
    return withUnsafeBytes(of: &size) { Data($0) }
}
var records = Data()
let pixels = [
    "0000eeeeee0000",
    "00eellllllhh00",
    "0ellltllllmmh0",
    "elllttttllmmmh",
    "ellttlttlmmddh",
    "ellllllldmdddh",
    "elldlllddmdddh",
    "elllttllmmdddh",
    "eltttttmdddddh",
    "hdmtlmdddddddh",
    "0hddddddddddh0",
    "00hhhhhhhhhh00"
]
let shades: [Character: UInt32] = ["e": 0xffdb71, "l": 0xfabf52, "t": 0xe09437,
    "m": 0xe7a346, "d": 0xb56127, "h": 0x7e3a19]
for (size, record) in renders {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    ctx.scaleBy(x: scale, y: scale)
    let bounds = CGRect(x: 90, y: 90, width: 844, height: 844)
    let path = CGPath(roundedRect: bounds, cornerWidth: 190, cornerHeight: 190, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: rgb(0x25170b, 0.5))
    ctx.setFillColor(rgb(0x422719))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [rgb(0x5b3a24), rgb(0x28150f)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 920), end: CGPoint(x: 720, y: 90), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: UInt32, _ a: CGFloat = 1) {
        ctx.setFillColor(rgb(color, a))
        ctx.fill(CGRect(x: x, y: y, width: w, height: h))
    }
    let unit: CGFloat = 39
    for (y, row) in pixels.enumerated() {
        for (x, pixel) in row.enumerated() {
            guard let color = shades[pixel] else { continue }
            let left = 224 + CGFloat(x) * unit
            let bottom = 743 - CGFloat(y + 1) * unit
            rect(left + 14, bottom - 22, unit + 0.25, unit + 0.25, 0x21110b, 0.35)
            rect(left, bottom, unit + 0.3, unit + 0.3, color)
        }
    }
    rect(725, 744, 105, 18, 0xffdc7d, 0.72)
    rect(812, 676, 18, 86, 0xffdc7d, 0.72)
    rect(195, 263, 90, 16, 0xffdc7d, 0.55)
    rect(195, 263, 16, 80, 0xffdc7d, 0.55)
    let imageData = NSMutableData()
    let png = CGImageDestinationCreateWithData(imageData as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(png, ctx.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(png))
    records.append(contentsOf: record.utf8)
    records.append(sizeBytes(imageData.length + 8))
    records.append(imageData as Data)
}
var icns = Data("icns".utf8)
icns.append(sizeBytes(records.count + 8))
icns.append(records)
try icns.write(to: root)
