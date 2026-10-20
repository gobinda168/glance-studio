// Draws the installer window's background: warm off-white, one coral glow behind the app, an arrow to Applications.
// Run: swift scripts/dmg-background.swift <out dir>  → background.png (1x), background@2x.png
// Then: tiffutil -cathidpicheck background.png background@2x.png -out assets/dmg/background.tiff (committed; release.sh
// uses it). Icon centres must match scripts/dmg-settings.py.
import AppKit

let width: CGFloat = 640, height: CGFloat = 400
let app = CGPoint(x: 170, y: 190), apps = CGPoint(x: 470, y: 190) // icon centres, Finder coordinates (top-left origin)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
          blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func render(scale: CGFloat) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: width, height: height)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let cg = NSGraphicsContext.current!.cgContext
  // Flip so y runs down, like Finder's icon positions.
  cg.translateBy(x: 0, y: height)
  cg.scaleBy(x: 1, y: -1)

  // Base: warm off-white, a touch deeper at the bottom.
  NSGradient(starting: color(0xfbf8f2), ending: color(0xf1ebe0))!
    .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

  // The one light: a soft coral bloom behind the app icon.
  let glow = NSGradient(colors: [color(0xe8643c, 0.20), color(0xf0a07a, 0.08), color(0xf0a07a, 0)],
                        atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
  glow.draw(fromCenter: app, radius: 0, toCenter: app, radius: 150, options: [])

  // Arrow: a shallow arc, fading in from the app's side.
  let start = CGPoint(x: app.x + 92, y: app.y - 4), end = CGPoint(x: apps.x - 92, y: app.y - 4)
  let control = CGPoint(x: (start.x + end.x) / 2, y: app.y - 34)
  let arc = CGMutablePath()
  arc.move(to: start)
  arc.addQuadCurve(to: end, control: control)
  cg.saveGState()
  cg.addPath(arc.copy(strokingWithWidth: 2.5, lineCap: .round, lineJoin: .round, miterLimit: 1))
  cg.clip()
  NSGradient(starting: color(0xe8643c, 0.15), ending: color(0xe8643c, 0.95))!
    .draw(in: NSRect(x: start.x - 2, y: control.y - 4, width: end.x - start.x + 4, height: start.y - control.y + 8), angle: 0)
  cg.restoreGState()
  // Head, along the curve's end tangent.
  let angle = atan2(end.y - control.y, end.x - control.x)
  let head = CGMutablePath()
  for side in [-1.0, 1.0] as [CGFloat] {
    let a = angle + .pi + side * 0.5
    head.move(to: end)
    head.addLine(to: CGPoint(x: end.x + 11 * cos(a), y: end.y + 11 * sin(a)))
  }
  cg.addPath(head)
  cg.setStrokeColor(color(0xe8643c, 0.95).cgColor)
  cg.setLineWidth(2.5)
  cg.setLineCap(.round)
  cg.strokePath()

  // Caption under the icons' labels.
  let paragraph = NSMutableParagraphStyle()
  paragraph.alignment = .center
  func line(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, hex: UInt32) {
    NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color(hex), .paragraphStyle: paragraph,
    ]).draw(in: NSRect(x: 0, y: height - y - size * 1.4, width: width, height: size * 1.6))
  }
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep) // unflipped, for text
  line("Drag Glance Studio into Applications", y: 318, size: 14, weight: .semibold, hex: 0x1c1a17)
  line("Then open it from Applications or Spotlight.", y: 342, size: 12, weight: .regular, hex: 0x6b655c)
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try! render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
