// Renders the Stay Awake app icon (crescent moon and z's on an indigo squircle) and writes an .icns.
// Usage: swift Tools/make-icon.swift Resources/AppIcon.icns [docs/icon.png]
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
let icnsPath = args.first ?? "Resources/AppIcon.icns"
let previewPath = args.count > 1 ? args[1] : nil

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let u = s / 1024

    // Tile: Apple's macOS icon grid, 824 pt square inset 100 pt, corner radius ~22.5 %.
    let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * u, yRadius: 185 * u)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 24 * u,
                  color: NSColor.black.withAlphaComponent(0.30).cgColor)
    NSColor(srgbRed: 0.20, green: 0.13, blue: 0.55, alpha: 1).setFill()
    tilePath.fill()
    ctx.restoreGState()

    ctx.saveGState()
    tilePath.addClip()
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.13, green: 0.08, blue: 0.40, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.30, green: 0.17, blue: 0.72, alpha: 1), 0.55),
        (NSColor(srgbRed: 0.52, green: 0.32, blue: 0.95, alpha: 1), 1.0))!
        .draw(in: tile, angle: -60)
    // Soft top-left highlight
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: CGPoint(x: tile.minX + tile.width * 0.25, y: tile.maxY), radius: 0,
              toCenter: CGPoint(x: tile.minX + tile.width * 0.25, y: tile.maxY), radius: tile.width * 0.95,
              options: [])
    ctx.restoreGState()

    // Crescent moon: a disc with a second disc cut out, drawn in its own layer so the cut does not touch the tile.
    let moonColor = NSColor(srgbRed: 1.0, green: 0.95, blue: 0.82, alpha: 1)
    let mc = CGPoint(x: tile.minX + 350 * u, y: tile.minY + 330 * u)
    let mr: CGFloat = 250 * u
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * u), blur: 44 * u,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    moonColor.setFill()
    NSBezierPath(ovalIn: CGRect(x: mc.x - mr, y: mc.y - mr, width: 2 * mr, height: 2 * mr)).fill()
    ctx.setBlendMode(.destinationOut)
    let cut = CGPoint(x: mc.x + 118 * u, y: mc.y + 108 * u)
    let cr: CGFloat = 222 * u
    NSBezierPath(ovalIn: CGRect(x: cut.x - cr, y: cut.y - cr, width: 2 * cr, height: 2 * cr)).fill()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // z z z, rising to the top right
    func z(at p: CGPoint, size: CGFloat) {
        let desc = NSFont.systemFont(ofSize: size, weight: .heavy).fontDescriptor.withDesign(.rounded)!
        let font = NSFont(descriptor: desc, size: size)!
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: "z", attributes: attrs)
        let sz = str.size()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * u), blur: 24 * u,
                      color: NSColor.black.withAlphaComponent(0.30).cgColor)
        str.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
        ctx.restoreGState()
    }
    z(at: CGPoint(x: tile.minX + 520 * u, y: tile.minY + 470 * u), size: 150 * u)
    z(at: CGPoint(x: tile.minX + 620 * u, y: tile.minY + 580 * u), size: 200 * u)
    z(at: CGPoint(x: tile.minX + 740 * u, y: tile.minY + 700 * u), size: 260 * u)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Write the .icns container directly (no iconutil dependency). Each entry is a PNG.
let entries: [(String, Int)] = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
    ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512),
]
var cache: [Int: Data] = [:]
func png(_ px: Int) -> Data {
    if let d = cache[px] { return d }
    let d = render(px); cache[px] = d; return d
}
func be32(_ v: Int) -> Data {
    var n = UInt32(v).bigEndian
    return Data(bytes: &n, count: 4)
}
var body = Data()
for (type, px) in entries {
    let data = png(px)
    body.append(type.data(using: .ascii)!)
    body.append(be32(data.count + 8))
    body.append(data)
}
var icns = Data()
icns.append("icns".data(using: .ascii)!)
icns.append(be32(body.count + 8))
icns.append(body)

let fm = FileManager.default
try? fm.createDirectory(atPath: (icnsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
try! icns.write(to: URL(fileURLWithPath: icnsPath))
if let preview = previewPath {
    try? fm.createDirectory(atPath: (preview as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! png(512).write(to: URL(fileURLWithPath: preview))
}
print("wrote \(icnsPath) (\(icns.count) bytes)")
