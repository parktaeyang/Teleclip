// Teleclip 앱 아이콘 생성기 (Core Graphics로 직접 그림, SF Symbol 미사용).
// 빌드 시에만 쓰인다: swiftc -D ICON_GENERATOR TeleclipIcon.swift -o gen && gen <iconset 디렉토리>
#if ICON_GENERATOR
import AppKit

func drawIcon(pixels: Int) -> Data? {
    let s = CGFloat(pixels)
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS 아이콘 규격: 캔버스의 약 82%를 쓰는 둥근 사각형
    let body = CGRect(x: s * 0.09, y: s * 0.09, width: s * 0.82, height: s * 0.82)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 그림자
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0.10, green: 0.25, blue: 0.60, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // 배경 그라데이션 (위: 밝은 파랑 → 아래: 진한 남색)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [CGColor(red: 0.25, green: 0.62, blue: 1.00, alpha: 1),
                  CGColor(red: 0.10, green: 0.22, blue: 0.62, alpha: 1)] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: s / 2, y: body.maxY),
                           end: CGPoint(x: s / 2, y: body.minY), options: [])
    ctx.restoreGState()

    // 뷰파인더 모서리 4개
    let white = CGColor(gray: 1, alpha: 1)
    let frame = body.insetBy(dx: body.width * 0.17, dy: body.height * 0.17)
    let arm = frame.width * 0.24
    let lw = max(1, s * 0.035)
    ctx.setStrokeColor(white)
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: frame.minX, y: frame.maxY),  1, -1),   // 좌상
        (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),   // 우상
        (CGPoint(x: frame.minX, y: frame.minY),  1,  1),   // 좌하
        (CGPoint(x: frame.maxX, y: frame.minY), -1,  1),   // 우하
    ]
    for (p, dx, dy) in corners {
        ctx.move(to: CGPoint(x: p.x + dx * arm, y: p.y))
        ctx.addLine(to: p)
        ctx.addLine(to: CGPoint(x: p.x, y: p.y + dy * arm))
        ctx.strokePath()
    }

    // 텍스트 줄 3개 (길이를 달리해서 글줄처럼 보이게)
    let inner = frame.insetBy(dx: frame.width * 0.20, dy: frame.height * 0.24)
    let lineH = max(1, s * 0.05)
    let widths: [CGFloat] = [1.0, 0.82, 0.56]
    for (i, w) in widths.enumerated() {
        let y = inner.maxY - lineH / 2 - CGFloat(i) * (inner.height - lineH) / 2
        let r = CGRect(x: inner.minX, y: y - lineH / 2, width: inner.width * w, height: lineH)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
        ctx.setFillColor(CGColor(gray: 1, alpha: i == 2 ? 0.75 : 0.95))
        ctx.fillPath()
    }

    guard let img = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: gen <iconset-dir>\n".data(using: .utf8)!)
    exit(2)
}
let dir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

// iconutil이 요구하는 10장 (16~512 @1x/@2x)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
        guard let png = drawIcon(pixels: base * scale) else { print("fail \(name)"); exit(1) }
        try png.write(to: dir.appendingPathComponent(name))
    }
}
#endif
