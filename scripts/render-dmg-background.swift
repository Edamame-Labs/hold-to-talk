import AppKit
import CoreImage
import Foundation

let outputWidth: CGFloat = 720
let outputHeight: CGFloat = 460
let canvasRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)

let titleRect = CGRect(x: 56, y: 330, width: 608, height: 52)
let subtitleRect = CGRect(x: 88, y: 292, width: 544, height: 24)
let requirementRect = CGRect(x: 212, y: 96, width: 296, height: 32)
let leftDropRect = CGRect(x: 116, y: 138, width: 144, height: 102)
let rightDropRect = CGRect(x: 460, y: 138, width: 144, height: 102)
let footerRect = CGRect(x: 122, y: 60, width: 476, height: 18)
let arrowY: CGFloat = 194
let arrowStartX: CGFloat = 298
let arrowEndX: CGFloat = 422

guard CommandLine.arguments.count >= 2 else {
  fputs("usage: render-dmg-background.swift <output> [texture-image]\n", stderr)
  exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let textureURL = CommandLine.arguments.count >= 3 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil
let minimumSystemVersion = CommandLine.arguments.dropFirst(3).first(where: isVersionString) ?? "15.0"

guard
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(outputWidth),
    pixelsHigh: Int(outputHeight),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  )
else {
  fputs("error: failed to create bitmap target\n", stderr)
  exit(1)
}

NSGraphicsContext.saveGraphicsState()

guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
  fputs("error: failed to create graphics context\n", stderr)
  exit(1)
}

NSGraphicsContext.current = graphicsContext

guard let context = NSGraphicsContext.current?.cgContext else {
  fputs("error: failed to access graphics context\n", stderr)
  exit(1)
}

func drawBaseFill(in rect: CGRect) {
  NSColor(calibratedRed: 0.978, green: 0.972, blue: 0.962, alpha: 1.0).setFill()
  rect.fill()
}

func drawTexture(from url: URL, in rect: CGRect, context: CGContext) {
  guard
    let data = try? Data(contentsOf: url),
    let inputImage = CIImage(data: data)
  else {
    return
  }

  let ciContext = CIContext(options: nil)
  let blur = CIFilter(name: "CIGaussianBlur")
  blur?.setValue(inputImage, forKey: kCIInputImageKey)
  blur?.setValue(22.0, forKey: kCIInputRadiusKey)

  guard
    let blurredImage = blur?.outputImage?.cropped(to: inputImage.extent),
    let cgImage = ciContext.createCGImage(blurredImage, from: inputImage.extent)
  else {
    return
  }

  let sourceRect = inputImage.extent
  let targetAspect = rect.width / rect.height
  let sourceAspect = sourceRect.width / sourceRect.height

  var cropRect = sourceRect
  if sourceAspect > targetAspect {
    let cropWidth = sourceRect.height * targetAspect
    cropRect.origin.x += (sourceRect.width - cropWidth) / 2
    cropRect.size.width = cropWidth
  } else {
    let cropHeight = sourceRect.width / targetAspect
    cropRect.origin.y += (sourceRect.height - cropHeight) / 2
    cropRect.size.height = cropHeight
  }

  let blurredNSImage = NSImage(cgImage: cgImage, size: sourceRect.size)
  blurredNSImage.draw(in: rect, from: cropRect, operation: NSCompositingOperation.sourceOver, fraction: 0.08)

  NSColor(calibratedRed: 1.0, green: 0.998, blue: 0.992, alpha: 0.90).setFill()
  rect.fill()
}

func drawTopGlow(in rect: CGRect) {
  let gradient = NSGradient(
    colors: [
      NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.52),
      NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.06)
    ]
  )
  gradient?.draw(in: CGRect(x: rect.minX, y: rect.midY - 30, width: rect.width, height: rect.height / 2 + 30), angle: 90)
}

func drawRequirementsBadge() {
  let badgePath = NSBezierPath(roundedRect: requirementRect, xRadius: 15, yRadius: 15)
  NSColor(calibratedRed: 0.949, green: 0.973, blue: 0.987, alpha: 0.96).setFill()
  badgePath.fill()

  NSColor(calibratedRed: 0.529, green: 0.682, blue: 0.835, alpha: 0.95).setStroke()
  badgePath.lineWidth = 1.0
  badgePath.stroke()

  let style = NSMutableParagraphStyle()
  style.alignment = .center

  let requirements = NSAttributedString(
    string: "Requires macOS \(displayRequirement(minimumSystemVersion)) and Apple Silicon",
    attributes: [
      .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: NSColor(calibratedRed: 0.210, green: 0.298, blue: 0.392, alpha: 1.0),
      .paragraphStyle: style
    ]
  )

  requirements.draw(in: requirementRect.insetBy(dx: 8, dy: 6))
}

func drawDropZone(in rect: CGRect, dashed: Bool) {
  let shadowInset: CGFloat = dashed ? -4 : -8
  let shadowRect = rect.insetBy(dx: shadowInset, dy: shadowInset)
  let shadowPath = NSBezierPath(roundedRect: shadowRect, xRadius: 26, yRadius: 26)
  NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: dashed ? 0.42 : 0.34).setFill()
  shadowPath.fill()

  let path = NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22)
  if dashed {
    NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.52).setFill()
    path.fill()
    NSColor(calibratedRed: 0.808, green: 0.800, blue: 0.790, alpha: 0.9).setStroke()
    path.lineWidth = 2.0
    let pattern: [CGFloat] = [12, 8]
    path.setLineDash(pattern, count: pattern.count, phase: 0)
    path.stroke()
  } else {
    NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.76).setFill()
    path.fill()
    NSColor(calibratedRed: 0.902, green: 0.886, blue: 0.860, alpha: 0.92).setStroke()
    path.lineWidth = 1.2
    path.stroke()
  }
}

func drawApplicationsFolder(in rect: CGRect) {
  let bodyRect = CGRect(x: rect.minX + 20, y: rect.minY + 18, width: 104, height: 70)
  let tabRect = CGRect(x: bodyRect.minX + 10, y: bodyRect.maxY - 2, width: 34, height: 16)

  let tabPath = NSBezierPath(roundedRect: tabRect, xRadius: 8, yRadius: 8)
  let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 14, yRadius: 14)

  let tabGradient = NSGradient(
    colors: [
      NSColor(calibratedRed: 0.651, green: 0.855, blue: 0.992, alpha: 0.95),
      NSColor(calibratedRed: 0.522, green: 0.765, blue: 0.960, alpha: 0.95)
    ]
  )
  tabGradient?.draw(in: tabPath, angle: 90)

  let bodyGradient = NSGradient(
    colors: [
      NSColor(calibratedRed: 0.420, green: 0.761, blue: 0.964, alpha: 0.97),
      NSColor(calibratedRed: 0.278, green: 0.655, blue: 0.912, alpha: 0.97)
    ]
  )
  bodyGradient?.draw(in: bodyPath, angle: 90)

  NSColor(calibratedRed: 0.267, green: 0.553, blue: 0.812, alpha: 0.42).setStroke()
  tabPath.lineWidth = 1.0
  bodyPath.lineWidth = 1.0
  tabPath.stroke()
  bodyPath.stroke()

  let highlightPath = NSBezierPath()
  highlightPath.move(to: CGPoint(x: bodyRect.minX + 12, y: bodyRect.maxY - 10))
  highlightPath.line(to: CGPoint(x: bodyRect.maxX - 12, y: bodyRect.maxY - 10))
  NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.32).setStroke()
  highlightPath.lineWidth = 2.0
  highlightPath.stroke()
}

func drawTitle(in rect: CGRect) {
  let style = NSMutableParagraphStyle()
  style.alignment = .center

  let title = NSAttributedString(
    string: "Drag Hold to Talk to Applications",
    attributes: [
      .font: NSFont.systemFont(ofSize: 34, weight: .bold),
      .foregroundColor: NSColor(calibratedRed: 0.164, green: 0.148, blue: 0.132, alpha: 1.0),
      .paragraphStyle: style
    ]
  )

  let subtitle = NSAttributedString(
    string: "Drag the app into Applications, then open it there.",
    attributes: [
      .font: NSFont.systemFont(ofSize: 17, weight: .medium),
      .foregroundColor: NSColor(calibratedRed: 0.314, green: 0.286, blue: 0.255, alpha: 0.92),
      .paragraphStyle: style
    ]
  )

  let footer = NSAttributedString(
    string: "Open the copy in Applications to get started.",
    attributes: [
      .font: NSFont.systemFont(ofSize: 13, weight: .medium),
      .foregroundColor: NSColor(calibratedRed: 0.427, green: 0.384, blue: 0.333, alpha: 0.88),
      .paragraphStyle: style
    ]
  )

  title.draw(in: titleRect)
  subtitle.draw(in: subtitleRect)
  footer.draw(in: footerRect)
}

func drawArrow(in context: CGContext) {
  context.saveGState()
  context.setStrokeColor(NSColor(calibratedRed: 0.709, green: 0.648, blue: 0.529, alpha: 1.0).cgColor)
  context.setLineWidth(4.0)
  context.setLineCap(.round)
  context.setLineDash(phase: 0, lengths: [])
  context.move(to: CGPoint(x: arrowStartX, y: arrowY))
  context.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
  context.strokePath()

  context.setLineWidth(4.0)
  context.move(to: CGPoint(x: arrowEndX, y: arrowY))
  context.addLine(to: CGPoint(x: arrowEndX - 18, y: arrowY + 12))
  context.move(to: CGPoint(x: arrowEndX, y: arrowY))
  context.addLine(to: CGPoint(x: arrowEndX - 18, y: arrowY - 12))
  context.strokePath()
  context.restoreGState()
}

func isVersionString(_ candidate: String) -> Bool {
  candidate.range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression) != nil
}

func displayRequirement(_ version: String) -> String {
  let components = version.split(separator: ".").map(String.init)
  if components.count >= 2, components[1] != "0" {
    return "\(components[0]).\(components[1])+"
  }
  return "\(components[0])+"
}

drawBaseFill(in: canvasRect)
drawTopGlow(in: canvasRect)
drawRequirementsBadge()
drawDropZone(in: leftDropRect, dashed: false)
drawDropZone(in: rightDropRect, dashed: true)
drawApplicationsFolder(in: rightDropRect)
drawTitle(in: canvasRect)
drawArrow(in: context)

NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
  fputs("error: failed to encode PNG output\n", stderr)
  exit(1)
}

try pngData.write(to: outputURL)
