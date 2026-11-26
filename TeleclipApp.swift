import AppKit
import Carbon
import Vision
import ServiceManagement

// ============================================================
// Teleclip (메뉴바 앱)
//   전역 단축키로 화면 영역을 캡처 → Vision OCR(한/영) → 클립보드.
//   ⌃⇧2 : 열 구분 = 공백   /   ⌃⇧3 : 열 구분 = 탭(엑셀·시트용)
//   ⌃⇧4 : 스크린샷을 파일로 저장하고 화면 구석에 미리보기를 띄운다.
// ============================================================

// ---- 캡처 모드 ----
enum CaptureMode {
    case textSpace    // ⌃⇧2 : OCR → 클립보드 (열 구분 = 공백)
    case textTab      // ⌃⇧3 : OCR → 클립보드 (열 구분 = 탭)
    case screenshot   // ⌃⇧4 : 이미지 파일로 저장 → 미리보기

    var hotKeyID: UInt32 {
        switch self {
        case .textSpace: return 1
        case .textTab: return 2
        case .screenshot: return 3
        }
    }

    init?(hotKeyID: UInt32) {
        switch hotKeyID {
        case 1: self = .textSpace
        case 2: self = .textTab
        case 3: self = .screenshot
        default: return nil
        }
    }
}

// 영역을 드래그로 선택해 임시 PNG로 캡처한다. Esc로 취소하면 nil.
func captureRegion(extraArguments: [String] = []) -> URL? {
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("teleclip-\(UUID().uuidString).png")

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-i", "-x"] + extraArguments + [tmpURL.path]   // 인터랙티브, 셔터음 없음
    do { try task.run(); task.waitUntilExit() } catch { return nil }

    return FileManager.default.fileExists(atPath: tmpURL.path) ? tmpURL : nil
}

func loadCGImage(_ url: URL) -> CGImage? {
    NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

func copyToClipboard(_ text: String) {
    DispatchQueue.main.async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// ---- 캡처 → OCR → 클립보드 ----
func captureAndCopy(tab: Bool) {
    guard let tmpURL = captureRegion(extraArguments: ["-o"]) else { return }   // -o: 창 그림자 없음
    defer { try? FileManager.default.removeItem(at: tmpURL) }
    guard let cg = loadCGImage(tmpURL), let text = recognizeText(in: cg, tab: tab) else { return }
    copyToClipboard(text)
}

// Vision OCR(한/영). 인식된 글자가 없으면 nil.
func recognizeText(in cg: CGImage, tab: Bool) -> String? {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false   // ID·숫자·이메일은 사전 보정이 오히려 글자를 바꿔버림
    req.recognitionLanguages = ["ko-KR", "en-US"]

    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    guard (try? handler.perform([req])) != nil,
          let obs = req.results, !obs.isEmpty else { return nil }

    struct Piece { let text: String; let midY: Double; let minX: Double; let height: Double }
    let pieces: [Piece] = obs.compactMap { o in
        guard let s = o.topCandidates(1).first?.string else { return nil }
        let b = o.boundingBox
        return Piece(text: s, midY: Double(b.midY), minX: Double(b.minX), height: Double(b.height))
    }

    // 세로 위치로 같은 행 묶기 → 행 안에서는 가로 순서로 이어붙임.
    let byY = pieces.sorted { $0.midY > $1.midY }
    var rows: [[Piece]] = []
    for p in byY {
        if let rep = rows.last?.first,
           abs(p.midY - rep.midY) < max(rep.height, p.height) * 0.6 {
            rows[rows.count - 1].append(p)
        } else {
            rows.append([p])
        }
    }
    let colSep = tab ? "\t" : " "
    return rows
        .map { $0.sorted { $0.minX < $1.minX }.map { $0.text }.joined(separator: colSep) }
        .joined(separator: "\n")
}

// ---- 캡처 → 파일 저장 → 미리보기 ----
enum ScreenshotStore {
    // macOS 스크린샷 저장 위치 설정을 그대로 따른다. 설정이 없거나 폴더가 없으면 데스크탑.
    static func directory() -> URL {
        let fm = FileManager.default
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (loc as NSString).expandingTildeInPath, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
    }

    // 예: "Teleclip 2026-11-26 15.04.05.png" (같은 이름이 있으면 " (2)" 를 붙인다)
    static func newFileURL() -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dir = directory()
        let base = "Teleclip \(f.string(from: Date()))"
        var url = dir.appendingPathComponent("\(base).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n)).png")
            n += 1
        }
        return url
    }
}

func captureScreenshot() {
    guard let tmpURL = captureRegion() else { return }   // Esc로 취소 등
    // 임시 폴더에 먼저 찍고 옮긴다 → 저장 실패(폴더 접근 권한 등)를 취소와 구분해 알릴 수 있다.
    let dest = ScreenshotStore.newFileURL()
    do {
        try FileManager.default.moveItem(at: tmpURL, to: dest)
    } catch {
        try? FileManager.default.removeItem(at: tmpURL)
        DispatchQueue.main.async {
            (NSApp.delegate as? AppDelegate)?.alert(
                "스크린샷을 저장하지 못했습니다.\n\(dest.deletingLastPathComponent().path)\n(\(error.localizedDescription))")
        }
        return
    }
    DispatchQueue.main.async { PreviewController.shared.show(fileURL: dest) }
}

// ---- 미리보기 썸네일 ----
// 캡처 직후 화면 구석에 뜨는 작은 창. 마우스가 있는 화면에, 모든 Space·전체화면 앱 위에 띄운다.
//   클릭: 편집 창 열기 / 드래그: 다른 앱으로 파일 전달 / 우클릭: 메뉴 / 몇 초 뒤 자동으로 닫힘
final class PreviewController {
    static let shared = PreviewController()
    private var panel: NSPanel?
    private var timer: Timer?
    private let lifetime: TimeInterval = 6
    var isDragging = false

    func show(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL),
              image.size.width > 0, image.size.height > 0 else { return }
        close()

        // 썸네일 크기: 비율을 유지하며 240×180 안에 맞추되, 너무 작아지지 않게 한다.
        let scale = min(240 / image.size.width, 180 / image.size.height, 1)
        let size = NSSize(width: max(image.size.width * scale, 96),
                          height: max(image.size.height * scale, 64))

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = NSRect(x: visible.maxX - size.width - 20, y: visible.minY + 20,
                           width: size.width, height: size.height)

        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false   // 메뉴바 앱은 대부분 비활성 상태라서 필수
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = PreviewView(frame: NSRect(origin: .zero, size: size), image: image, fileURL: fileURL)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
        panel = p
        scheduleClose()
    }

    private func scheduleClose() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in
            guard let self = self, let p = self.panel else { return }
            // 마우스가 올라가 있거나 드래그 중이면 닫지 않고 다시 기다린다.
            if self.isDragging || NSMouseInRect(NSEvent.mouseLocation, p.frame, false) {
                self.scheduleClose()
            } else {
                self.close()
            }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        isDragging = false
        panel?.orderOut(nil)
        panel = nil
    }
}

// 패널이 key가 아니어도 첫 클릭에 바로 반응하는 버튼
final class PreviewButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PreviewView: NSView, NSDraggingSource {
    private let image: NSImage
    private let fileURL: URL
    private var mouseDownPoint: NSPoint?
    private var dragStarted = false
    private var buttons: [NSButton] = []
    private var copyButton: NSButton?

    private func setCopyTitle(_ title: String) {
        copyButton?.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
    }

    init(frame: NSRect, image: NSImage, fileURL: URL) {
        self.image = image
        self.fileURL = fileURL
        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.5, alpha: 0.6).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let iv = NSImageView(frame: bounds)
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        iv.unregisterDraggedTypes()   // 이미지 뷰가 드롭 대상이 되지 않게 한다
        addSubview(iv)

        // 마우스를 올리면 나타나는 버튼: 왼쪽 위 닫기, 오른쪽 위 삭제
        let closeBtn = makeButton(symbol: "xmark.circle.fill", fallback: "✕", tip: "닫기",
                                  action: #selector(dismiss))
        closeBtn.frame.origin = NSPoint(x: 4, y: bounds.maxY - 26)
        closeBtn.autoresizingMask = [.maxXMargin, .minYMargin]
        let trashBtn = makeButton(symbol: "trash.circle.fill", fallback: "🗑", tip: "휴지통으로 이동",
                                  action: #selector(moveToTrash))
        trashBtn.frame.origin = NSPoint(x: bounds.maxX - 26, y: bounds.maxY - 26)
        trashBtn.autoresizingMask = [.minXMargin, .minYMargin]
        // 아래 가운데: 이미지를 클립보드에 복사
        let copyBtn = PreviewButton(frame: NSRect(x: (bounds.width - 60) / 2, y: 6, width: 60, height: 22))
        copyBtn.isBordered = false
        copyBtn.wantsLayer = true
        copyBtn.layer?.backgroundColor = NSColor(white: 0, alpha: 0.65).cgColor
        copyBtn.layer?.cornerRadius = 11
        copyBtn.target = self
        copyBtn.action = #selector(copyImage)
        copyBtn.toolTip = "이미지를 클립보드에 복사"
        copyBtn.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        copyButton = copyBtn
        setCopyTitle("복사")

        buttons = [closeBtn, trashBtn, copyBtn]
        buttons.forEach { $0.isHidden = true; addSubview($0) }

        toolTip = "클릭: 편집 · 드래그: 다른 앱으로 전달 · 우클릭: 메뉴"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 는 지원하지 않습니다") }

    private func makeButton(symbol: String, fallback: String, tip: String, action: Selector) -> NSButton {
        let b = PreviewButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        b.isBordered = false
        b.target = self
        b.action = action
        b.toolTip = tip
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, NSColor(white: 0, alpha: 0.65)]))
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config) {
            b.image = img
            b.imagePosition = .imageOnly
        } else {
            b.title = fallback
        }
        return b
    }

    // ---- 마우스 올림: 버튼 표시 ----
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { buttons.forEach { $0.isHidden = false } }
    override func mouseExited(with event: NSEvent)  { buttons.forEach { $0.isHidden = true } }

    // ---- 클릭: 열기 / 드래그: 파일 전달 ----
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let start = mouseDownPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        dragStarted = true
        PreviewController.shared.isDragging = true
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !dragStarted, mouseDownPoint != nil else { return }
        editFile()
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        PreviewController.shared.isDragging = false
        if operation != [] { PreviewController.shared.close() }   // 전달에 성공했으면 닫는다
    }

    // ---- 우클릭 메뉴 ----
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "편집 (도형·글씨)", action: #selector(editFile), keyEquivalent: "")
        m.addItem(withTitle: "미리보기 앱으로 열기", action: #selector(openFile), keyEquivalent: "")
        m.addItem(withTitle: "Finder에서 보기", action: #selector(revealInFinder), keyEquivalent: "")
        m.addItem(NSMenuItem.separator())
        m.addItem(withTitle: "이미지 복사", action: #selector(copyImage), keyEquivalent: "")
        m.addItem(withTitle: "텍스트 복사 (OCR)", action: #selector(copyText), keyEquivalent: "")
        m.addItem(NSMenuItem.separator())
        m.addItem(withTitle: "휴지통으로 이동", action: #selector(moveToTrash), keyEquivalent: "")
        m.addItem(withTitle: "닫기", action: #selector(dismiss), keyEquivalent: "")
        for it in m.items where it.action != nil { it.target = self }
        return m
    }

    @objc func dismiss() { PreviewController.shared.close() }

    @objc func editFile() {
        let url = fileURL
        PreviewController.shared.close()
        EditorController.shared.open(fileURL: url)
    }

    @objc func openFile() {
        NSWorkspace.shared.open(fileURL)
        PreviewController.shared.close()
    }

    @objc func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        PreviewController.shared.close()
    }

    @objc func copyImage() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        // 복사됐다는 것을 잠깐 보여 준 뒤 닫는다
        setCopyTitle("복사됨")
        copyButton?.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { PreviewController.shared.close() }
    }

    @objc func copyText() {
        let url = fileURL
        DispatchQueue.global().async {
            guard let cg = loadCGImage(url), let text = recognizeText(in: cg, tab: false) else {
                DispatchQueue.main.async { NSSound.beep() }   // 글자를 찾지 못함 → 창은 그대로 둔다
                return
            }
            copyToClipboard(text)
            DispatchQueue.main.async { PreviewController.shared.close() }
        }
    }

    @objc func moveToTrash() {
        do {
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            PreviewController.shared.close()
        } catch {
            NSSound.beep()
        }
    }
}

// ---- 편집 창: 스크린샷 위에 도형·글씨 넣기 ----
enum EditorTool: Int { case rect, arrow, pen, text }

struct Annotation {
    var tool: EditorTool
    var color: NSColor
    var lineWidth: CGFloat
    var points: [NSPoint]          // rect·arrow: [시작, 끝] / pen: 지나간 점들 / text: [왼쪽 위]
    var text: String = ""
    var fontSize: CGFloat = 0

    func draw() {
        color.setStroke()
        color.setFill()
        switch tool {
        case .rect:
            guard points.count >= 2 else { return }
            let a = points[0], b = points[1]
            let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            let path = NSBezierPath(roundedRect: r, xRadius: lineWidth * 0.6, yRadius: lineWidth * 0.6)
            path.lineWidth = lineWidth
            path.stroke()
        case .arrow:
            guard points.count >= 2 else { return }
            let a = points[0], b = points[1]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0.5 else { return }
            let head = min(max(lineWidth * 4.5, 12), len)      // 화살촉 길이
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            let base = NSPoint(x: b.x - ux * head, y: b.y - uy * head)
            let line = NSBezierPath()
            line.lineWidth = lineWidth
            line.lineCapStyle = .round
            line.move(to: a)
            line.line(to: base)
            line.stroke()
            let w = head * 0.45
            let tri = NSBezierPath()
            tri.move(to: b)
            tri.line(to: NSPoint(x: base.x - uy * w, y: base.y + ux * w))
            tri.line(to: NSPoint(x: base.x + uy * w, y: base.y - ux * w))
            tri.close()
            tri.fill()
        case .pen:
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: first)
            if points.count == 1 { path.line(to: first) }
            points.dropFirst().forEach { path.line(to: $0) }
            path.stroke()
        case .text:
            guard let p = points.first, !text.isEmpty else { return }
            (text as NSString).draw(at: p, withAttributes: [
                .font: EditorCanvas.font(size: fontSize), .foregroundColor: color,
            ])
        }
    }
}

// 이미지와 그 위의 주석을 그리는 뷰. 좌표는 이미지의 포인트 크기 기준(왼쪽 위가 원점)이고,
// 화면에는 bounds 스케일로 축소해 보여 준다.
final class EditorCanvas: NSView, NSTextFieldDelegate {
    let image: NSImage
    let lineWidth: CGFloat
    let fontSize: CGFloat
    var tool: EditorTool = .rect { didSet { if tool != oldValue { commitText() } } }
    var color: NSColor = .red { didSet { textField?.textColor = color } }
    private(set) var annotations: [Annotation] = []
    private var current: Annotation?
    private var textField: NSTextField?

    static func font(size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

    init(image: NSImage, displaySize: NSSize) {
        self.image = image
        // 큰 캡처를 축소해 보여 줄 때도 선·글자가 화면에서 비슷한 굵기로 보이게 한다.
        let scale = displaySize.width / image.size.width
        lineWidth = 3 / scale
        fontSize = 18 / scale
        super.init(frame: NSRect(origin: .zero, size: displaySize))
        setBoundsSize(image.size)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 는 지원하지 않습니다") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) { drawContent(includeCurrent: true) }

    func drawContent(includeCurrent: Bool) {
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero,
                   operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        annotations.forEach { $0.draw() }
        if includeCurrent { current?.draw() }
    }

    func add(_ a: Annotation) {
        annotations.append(a)
        needsDisplay = true
    }

    // ---- 그리기 ----
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        commitText()
        if tool == .text {
            beginText(at: p)
        } else {
            current = Annotation(tool: tool, color: color, lineWidth: lineWidth,
                                 points: tool == .pen ? [p] : [p, p])
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var c = current else { return }
        let p = convert(event.locationInWindow, from: nil)
        if c.tool == .pen { c.points.append(p) } else { c.points[1] = p }
        current = c
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let c = current else { return }
        current = nil
        // 드래그 없이 클릭만 한 사각형·화살표는 버린다
        if c.tool != .pen, let a = c.points.first, let b = c.points.last,
           hypot(a.x - b.x, a.y - b.y) < lineWidth { needsDisplay = true; return }
        add(c)
    }

    // ---- 글씨 ----
    private func beginText(at p: NSPoint) {
        let font = EditorCanvas.font(size: fontSize)
        let h = ceil(NSLayoutManager().defaultLineHeight(for: font)) + 4
        let f = NSTextField(frame: NSRect(x: p.x, y: p.y - h / 2,
                                          width: max(bounds.maxX - p.x - 4, fontSize * 4), height: h))
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = font
        f.textColor = color
        f.cell?.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.delegate = self
        addSubview(f)
        textField = f
        window?.makeFirstResponder(f)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    // 입력 중인 글씨를 주석으로 확정한다 (비어 있으면 버린다).
    func commitText() {
        guard let f = textField else { return }
        textField = nil
        let s = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = NSPoint(x: f.frame.minX + 2, y: f.frame.minY)   // 텍스트 필드 안쪽 여백 2pt
        let c = f.textColor ?? color
        f.delegate = nil
        f.removeFromSuperview()
        if !s.isEmpty {
            add(Annotation(tool: .text, color: c, lineWidth: 0, points: [origin], text: s, fontSize: fontSize))
        }
        needsDisplay = true
    }

    func undo() {
        if let f = textField {            // 입력 중인 글씨가 있으면 그것부터 취소
            textField = nil
            f.delegate = nil
            f.removeFromSuperview()
        } else if !annotations.isEmpty {
            annotations.removeLast()
        }
        needsDisplay = true
    }

    // 원본과 같은 픽셀 크기로 이미지 + 주석을 합성한다.
    func render() -> NSBitmapImageRep? {
        let src = image.representations.first
        let pw = src.map { $0.pixelsWide } ?? 0, ph = src.map { $0.pixelsHigh } ?? 0
        guard pw > 0, ph > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = image.size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = ctx.cgContext
        cg.translateBy(x: 0, y: image.size.height)   // 뷰와 같은 '왼쪽 위 원점' 좌표로 맞춘다
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        drawContent(includeCurrent: false)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

final class EditorController: NSObject, NSWindowDelegate {
    static let shared = EditorController()
    private var window: NSWindow?
    private var canvas: EditorCanvas?
    private var fileURL: URL?

    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),   // 빨강
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),   // 노랑
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),   // 초록
        NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1),   // 파랑
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),            // 검정
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),            // 흰색
    ]

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            color.setFill()
            path.fill()
            NSColor(white: 0.5, alpha: 0.8).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }

    func open(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL),
              image.size.width > 0, image.size.height > 0 else { NSSound.beep(); return }
        window?.close()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        // 화면의 85% 안에 들어오도록 축소해서 보여 준다 (저장은 원본 해상도 그대로).
        let toolbarH: CGFloat = 44, pad: CGFloat = 16, minW: CGFloat = 720, titleH: CGFloat = 28
        let maxW = visible.width * 0.85 - pad * 2
        let maxH = visible.height * 0.85 - toolbarH - pad * 2 - titleH
        let s = min(1, maxW / image.size.width, maxH / image.size.height)
        let disp = NSSize(width: max(floor(image.size.width * s), 1), height: max(floor(image.size.height * s), 1))
        let contentW = max(disp.width + pad * 2, minW)
        let contentH = disp.height + pad * 2 + toolbarH

        let w = NSWindow(contentRect: NSRect(x: visible.midX - contentW / 2, y: visible.midY - contentH / 2,
                                             width: contentW, height: contentH),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Teleclip 편집 — \(fileURL.lastPathComponent)"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))
        let c = EditorCanvas(image: image, displaySize: disp)
        c.setFrameOrigin(NSPoint(x: floor((contentW - disp.width) / 2), y: pad))
        content.addSubview(c)

        // 도구 막대: [도구] [색] [실행 취소] ……… [취소] [복사 + 저장]
        let tools = NSSegmentedControl(labels: ["사각형", "화살표", "펜", "글씨"], trackingMode: .selectOne,
                                       target: self, action: #selector(toolChanged(_:)))
        tools.selectedSegment = EditorTool.rect.rawValue
        let colors = NSSegmentedControl(images: EditorController.colors.map(EditorController.swatch),
                                        trackingMode: .selectOne, target: self, action: #selector(colorChanged(_:)))
        colors.selectedSegment = 0
        c.color = EditorController.colors[0]
        let undo = NSButton(title: "실행 취소", target: self, action: #selector(undoLast))
        undo.keyEquivalent = "z"
        undo.keyEquivalentModifierMask = .command
        undo.toolTip = "마지막으로 넣은 것을 지웁니다 (⌘Z)"
        let cancel = NSButton(title: "취소", target: self, action: #selector(cancelEdit))
        let done = NSButton(title: "복사 + 저장", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        done.toolTip = "편집한 이미지를 클립보드에 복사하고 파일에도 저장합니다 (Return)"

        let bar = NSStackView(frame: NSRect(x: pad, y: contentH - toolbarH + 8, width: contentW - pad * 2, height: 28))
        bar.orientation = .horizontal
        bar.spacing = 10
        [tools, colors, undo].forEach { bar.addView($0, in: .leading) }
        [cancel, done].forEach { bar.addView($0, in: .trailing) }
        content.addSubview(bar)

        w.contentView = content
        window = w
        canvas = c
        self.fileURL = fileURL

        NSApp.activate(ignoringOtherApps: true)   // 메뉴바 앱이라 직접 앞으로 가져와야 글씨 입력이 된다
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        if let t = EditorTool(rawValue: sender.selectedSegment) { canvas?.tool = t }
    }

    @objc private func colorChanged(_ sender: NSSegmentedControl) {
        let i = sender.selectedSegment
        if EditorController.colors.indices.contains(i) { canvas?.color = EditorController.colors[i] }
    }

    @objc private func undoLast() { canvas?.undo() }
    @objc private func cancelEdit() { window?.close() }

    @objc private func finish() {
        guard let c = canvas, let url = fileURL else { return }
        c.commitText()
        guard let rep = c.render(), let png = rep.representation(using: .png, properties: [:]) else {
            NSSound.beep()
            return
        }
        // 클립보드에 먼저 넣는다 → 파일 저장이 실패해도 붙여넣기는 할 수 있다.
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([out])
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            (NSApp.delegate as? AppDelegate)?.alert(
                "클립보드에는 복사했지만 파일로 저장하지 못했습니다.\n(\(error.localizedDescription))")
        }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        canvas = nil
        fileURL = nil
    }
}

#if TELECLIP_SELFTEST
// 개발용 자가 점검: 창 없이 주석 합성 결과만 PNG로 뽑는다.
//   swiftc -D TELECLIP_SELFTEST … && Teleclip --render-test <입력.png> <출력.png>
func runRenderSelfTest(input: String, output: String) -> Int32 {
    guard let image = NSImage(contentsOfFile: input) else { print("입력 이미지를 열 수 없음"); return 1 }
    let c = EditorCanvas(image: image, displaySize: image.size)
    let w = image.size.width, h = image.size.height
    let cs = EditorController.colors
    c.add(Annotation(tool: .rect, color: cs[0], lineWidth: c.lineWidth,
                     points: [NSPoint(x: w * 0.1, y: h * 0.1), NSPoint(x: w * 0.5, y: h * 0.35)]))
    c.add(Annotation(tool: .arrow, color: cs[3], lineWidth: c.lineWidth,
                     points: [NSPoint(x: w * 0.9, y: h * 0.9), NSPoint(x: w * 0.55, y: h * 0.4)]))
    c.add(Annotation(tool: .pen, color: cs[2], lineWidth: c.lineWidth,
                     points: (0...20).map { NSPoint(x: w * (0.1 + 0.03 * Double($0)),
                                                    y: h * (0.7 + 0.05 * sin(Double($0) / 2))) }))
    c.add(Annotation(tool: .text, color: cs[0], lineWidth: 0, points: [NSPoint(x: w * 0.1, y: h * 0.45)],
                     text: "왼쪽 위 Top-Left 123", fontSize: c.fontSize))
    guard let rep = c.render(), let png = rep.representation(using: .png, properties: [:]) else {
        print("합성 실패"); return 1
    }
    do { try png.write(to: URL(fileURLWithPath: output)) } catch { print("저장 실패: \(error)"); return 1 }
    print("입력 \(image.representations.first?.pixelsWide ?? 0)x\(image.representations.first?.pixelsHigh ?? 0)px"
          + " (\(Int(w))x\(Int(h))pt) → 출력 \(rep.pixelsWide)x\(rep.pixelsHigh)px")
    return 0
}
#endif

// ---- 화면 기록 권한 ----
enum ScreenPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    // 처음 한 번만 시스템 프롬프트를 띄우고 앱을 권한 목록에 등록한다.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    // 시스템 프롬프트는 처음 한 번만 뜨므로, 요청한 적이 있는지 기억해 둔다.
    static let requestedKey = "ScreenCaptureRequested"
    static var requestedOnce: Bool {
        get { UserDefaults.standard.bool(forKey: requestedKey) }
        set { UserDefaults.standard.set(newValue, forKey: requestedKey) }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // 권한을 허용해도 실행 중인 프로세스에는 반영되지 않는 경우가 흔해서 재시작이 기본 흐름.
    static func relaunch() {
        // 이전 프로세스가 끝날 때까지 기다린 뒤 다시 연다 (pid·경로는 인자로 전달)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c",
                       "while /bin/kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try p.run()
        } catch {
            // 재시작 프로세스를 못 띄웠으면 종료하지 않고 계속 실행한다
            let a = NSAlert()
            a.messageText = "다시 시작하지 못했습니다"
            a.informativeText = "Teleclip을 직접 종료한 뒤 다시 실행해 주세요. (\(error.localizedDescription))"
            a.runModal()
            return
        }
        NSApp.terminate(nil)
    }
}

// 메인 스레드에서 권한을 먼저 확인하고, 있을 때만 백그라운드에서 캡처한다.
func startCapture(_ mode: CaptureMode) {
    guard ScreenPermission.isGranted else {
        (NSApp.delegate as? AppDelegate)?.showPermissionAlert()
        return
    }
    PreviewController.shared.close()   // 이전 미리보기가 새 캡처에 찍히지 않게 한다
    DispatchQueue.global().async {
        switch mode {
        case .textSpace:  captureAndCopy(tab: false)
        case .textTab:    captureAndCopy(tab: true)
        case .screenshot: captureScreenshot()
        }
    }
}

// ---- 전역 단축키 (Carbon) ----
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [EventHotKeyRef?] = []

    func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard let mode = CaptureMode(hotKeyID: hkID.id) else { return noErr }
            DispatchQueue.main.async { startCapture(mode) }
            return noErr
        }, 1, &spec, nil, nil)

        let mods = UInt32(controlKey | shiftKey)
        add(id: CaptureMode.textSpace.hotKeyID,  key: UInt32(kVK_ANSI_2), mods: mods)  // ⌃⇧2 → 공백
        add(id: CaptureMode.textTab.hotKeyID,    key: UInt32(kVK_ANSI_3), mods: mods)  // ⌃⇧3 → 탭
        add(id: CaptureMode.screenshot.hotKeyID, key: UInt32(kVK_ANSI_4), mods: mods)  // ⌃⇧4 → 스크린샷
    }

    private func add(id: UInt32, key: UInt32, mods: UInt32) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x54_45_4C_43), id: id)  // 'TELC'
        RegisterEventHotKey(key, mods, hkID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

// ---- 메뉴바 앱 ----
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var loginMenuItem: NSMenuItem?
    var permissionMenuItem: NSMenuItem?
    var relaunchMenuItem: NSMenuItem?
    var alertShowing = false
    var waitingForSettings = false   // 설정 앱에 다녀오는 중
    var settingsActivated = false    // 그 사이 시스템 설정이 실제로 활성화됨
    var pendingSettingsReturn = false   // 메뉴가 닫힌 뒤 settingsReturned() 를 호출해야 함

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Teleclip")
            if btn.image == nil { btn.title = "✂︎" }
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false   // isEnabled를 직접 제어

        let perm = NSMenuItem(title: "", action: #selector(permissionItemClicked), keyEquivalent: "")
        menu.addItem(perm)
        permissionMenuItem = perm
        let relaunch = NSMenuItem(title: "다시 시작 (권한 적용)", action: #selector(relaunchApp), keyEquivalent: "")
        menu.addItem(relaunch)
        relaunchMenuItem = relaunch
        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: "캡처 → 클립보드 (공백)   ⌃⇧2", action: #selector(capSpace), keyEquivalent: "")
        menu.addItem(withTitle: "캡처 → 클립보드 (탭)     ⌃⇧3", action: #selector(capTab), keyEquivalent: "")
        menu.addItem(withTitle: "스크린샷 → 미리보기       ⌃⇧4", action: #selector(capShot), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        let login = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(login)
        loginMenuItem = login
        updateLoginState()

        menu.addItem(NSMenuItem.separator())
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "Teleclip v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false   // 표시 전용 (autoenablesItems = false 라서 유지됨)
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "종료", action: #selector(quit), keyEquivalent: "q")
        for it in menu.items where it.action != nil { it.target = self }
        statusItem.menu = menu

        HotKeys.shared.register()
        updatePermissionState()

        // 설정 앱에서 Teleclip으로 돌아온 것을 감지
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // 보조: 시스템 설정이 종료된 경우에도 돌아온 것으로 간주
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // 개발용: 캡처 없이 창만 띄워 본다.
        //   Teleclip --preview-file <이미지 경로>   미리보기 썸네일
        //   Teleclip --edit-file <이미지 경로>      편집 창
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--preview-file"), i + 1 < args.count {
            PreviewController.shared.show(fileURL: URL(fileURLWithPath: args[i + 1]))
            return
        }
        if let i = args.firstIndex(of: "--edit-file"), i + 1 < args.count {
            EditorController.shared.open(fileURL: URL(fileURLWithPath: args[i + 1]))
            return
        }

        if !ScreenPermission.isGranted {
            NSApp.activate(ignoringOtherApps: true)
            showPermissionAlert()
        }
    }

    @objc func capSpace() { startCapture(.textSpace) }
    @objc func capTab()   { startCapture(.textTab) }
    @objc func capShot()  { startCapture(.screenshot) }
    @objc func quit()     { NSApp.terminate(nil) }

    // ---- 로그인 항목 토글 (macOS 13+) ----
    @objc func toggleLogin() {
        guard #available(macOS 13.0, *) else {
            alert("로그인 시 자동 실행은 macOS 13 이상에서 지원됩니다.")
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("자동 실행 설정 실패: \(error.localizedDescription)")
        }
        updateLoginState()
    }

    func updateLoginState() {
        guard let item = loginMenuItem else { return }
        if #available(macOS 13.0, *) {
            item.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        } else {
            item.isEnabled = false
        }
    }

    // ---- 화면 기록 권한 UI ----
    func menuWillOpen(_ menu: NSMenu) {
        updatePermissionState()
        updateLoginState()
        // 설정에 다녀온 뒤 메뉴바 아이콘으로 돌아온 경우에도 다시 시작 안내를 띄운다.
        // 메뉴 추적 중에는 알림을 띄우지 않도록 메뉴가 닫힌 뒤(menuDidClose)에 처리한다.
        if waitingForSettings && settingsActivated { pendingSettingsReturn = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard pendingSettingsReturn else { return }
        pendingSettingsReturn = false
        DispatchQueue.main.async { [weak self] in self?.settingsReturned() }
    }

    func updatePermissionState() {
        let ok = ScreenPermission.isGranted
        permissionMenuItem?.title = ok ? "화면 기록 권한: 허용됨" : "화면 기록 권한 필요 — 허용하기…"
        permissionMenuItem?.isEnabled = !ok
        relaunchMenuItem?.isHidden = ok
    }

    @objc func permissionItemClicked() { showPermissionAlert() }
    @objc func relaunchApp() { ScreenPermission.relaunch() }

    @objc func appActivated(_ n: Notification) {
        guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if a.bundleIdentifier == "com.apple.systempreferences" {
            if waitingForSettings { settingsActivated = true }   // 설정에 실제로 다녀왔는지 추적
        } else if a.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            settingsReturned()
        }
    }

    @objc func appTerminated(_ n: Notification) {
        guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              a.bundleIdentifier == "com.apple.systempreferences" else { return }
        settingsReturned()
    }

    func settingsReturned() {
        // 시스템 설정이 실제로 활성화된 적이 있어야 "설정에서 돌아옴"으로 본다 (알림 중이면 플래그 유지)
        guard waitingForSettings, settingsActivated, !alertShowing else { return }
        waitingForSettings = false
        settingsActivated = false
        updatePermissionState()
        showRelaunchAlert()
    }

    func showPermissionAlert() {
        guard !alertShowing else { return }
        alertShowing = true
        defer { alertShowing = false }
        NSApp.activate(ignoringOtherApps: true)

        let a = NSAlert()
        a.messageText = "화면 기록 권한이 필요합니다"
        a.informativeText = "화면의 글자를 읽으려면 시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 Teleclip을 허용해 주세요. 허용한 뒤에는 Teleclip을 다시 시작해야 적용됩니다."
        let requested = ScreenPermission.requestedOnce
        a.addButton(withTitle: "권한 허용")
        if requested { a.addButton(withTitle: "다시 시작") }   // 이미 허용했지만 아직 반영 전인 경우
        a.addButton(withTitle: "나중에")
        let r = a.runModal()
        if r == .alertSecondButtonReturn && requested { ScreenPermission.relaunch(); return }
        guard r == .alertFirstButtonReturn else { return }

        waitingForSettings = true
        settingsActivated = false
        // 항상 request()를 불러 목록 등록을 시도한다 (TCC 초기화·번들 ID 변경 대비).
        // 이미 요청한 적이 있는데도 허용되지 않았다면 시스템 프롬프트가 안 뜰 수 있으니 설정을 직접 연다.
        let granted = ScreenPermission.request()
        ScreenPermission.requestedOnce = true
        if !granted && requested { ScreenPermission.openSettings() }
    }

    func showRelaunchAlert() {
        guard !alertShowing else { return }
        alertShowing = true
        defer { alertShowing = false }
        NSApp.activate(ignoringOtherApps: true)

        let a = NSAlert()
        a.messageText = "변경 사항을 적용하려면 다시 시작하세요"
        a.informativeText = "화면 기록 권한을 허용했다면 Teleclip을 다시 시작해야 캡처가 동작합니다."
        a.addButton(withTitle: "다시 시작")
        a.addButton(withTitle: "나중에")
        if a.runModal() == .alertFirstButtonReturn { ScreenPermission.relaunch() }
    }

    func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Teleclip"
        a.informativeText = msg
        a.runModal()
    }
}

let app = NSApplication.shared
#if TELECLIP_SELFTEST
if let i = CommandLine.arguments.firstIndex(of: "--render-test"), i + 2 < CommandLine.arguments.count {
    exit(runRenderSelfTest(input: CommandLine.arguments[i + 1], output: CommandLine.arguments[i + 2]))
}
#endif
app.setActivationPolicy(.accessory)   // Dock 아이콘 없음, 메뉴바에만 표시
let delegate = AppDelegate()
app.delegate = delegate
app.run()
