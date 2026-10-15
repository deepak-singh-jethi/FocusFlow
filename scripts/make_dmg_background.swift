import AppKit

// 1. Setup high-res 2x canvas (1320 x 840 for 660 x 420 pt window)
let ptWidth: CGFloat = 660
let ptHeight: CGFloat = 420
let scale: CGFloat = 2.0
let pixelWidth = Int(ptWidth * scale)
let pixelHeight = Int(ptHeight * scale)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelWidth,
    pixelsHigh: pixelHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Failed to create NSBitmapImageRep")
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("Failed to create NSGraphicsContext")
}
NSGraphicsContext.current = context

let cgContext = context.cgContext
cgContext.scaleBy(x: scale, y: scale)

// 2. Draw modern dark background
let bgRect = CGRect(x: 0, y: 0, width: ptWidth, height: ptHeight)
let darkBgColor = NSColor(red: 0.055, green: 0.063, blue: 0.075, alpha: 1.0)
darkBgColor.setFill()
bgRect.fill()

// Subtle radial spotlight in the center
let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradientColors = [
    NSColor.cyan.withAlphaComponent(0.06).cgColor,
    NSColor.clear.cgColor
] as CFArray
if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0]) {
    cgContext.drawRadialGradient(
        gradient,
        startCenter: CGPoint(x: ptWidth / 2, y: ptHeight / 2),
        startRadius: 10,
        endCenter: CGPoint(x: ptWidth / 2, y: ptHeight / 2),
        endRadius: 360,
        options: []
    )
}

// 3. Draw subtle guide arrow between FocusFlow.app (x: 170) and Applications (x: 490)
// Center arrow at x = 330, y = 210
let arrowPath = NSBezierPath()
let arrowY: CGFloat = ptHeight - 210 // Flip coordinate
arrowPath.move(to: NSPoint(x: 300, y: arrowY))
arrowPath.line(to: NSPoint(x: 350, y: arrowY))
arrowPath.line(to: NSPoint(x: 342, y: arrowY + 8))
arrowPath.move(to: NSPoint(x: 350, y: arrowY))
arrowPath.line(to: NSPoint(x: 342, y: arrowY - 8))
arrowPath.lineWidth = 2.5
arrowPath.lineCapStyle = .round
arrowPath.lineJoinStyle = .round

let arrowColor = NSColor(white: 1.0, alpha: 0.22)
arrowColor.setStroke()
arrowPath.stroke()

// 4. Instructional label
let labelText = "Drag FocusFlow to Applications to install"
let font = NSFont.systemFont(ofSize: 13, weight: .medium)
let textColor = NSColor(white: 1.0, alpha: 0.55)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: textColor
]
let textSize = labelText.size(withAttributes: attrs)
let labelPoint = NSPoint(x: (ptWidth - textSize.width) / 2, y: 70)
labelText.draw(at: labelPoint, withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()

// 5. Output PNG data
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to convert image representation to PNG")
}

let outputPath = "/tmp/dmg_background.png"
let outputURL = URL(fileURLWithPath: outputPath)
try pngData.write(to: outputURL)
print("Successfully generated high-resolution DMG background artwork at \(outputPath)")
