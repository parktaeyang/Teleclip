import AppKit
import Carbon
import Vision
import ServiceManagement

// ============================================================
// Teleclip (메뉴바 앱)
//   전역 단축키로 화면 영역을 캡처 → Vision OCR(한/영) → 클립보드.
//   ⌃⇧2 : 열 구분 = 공백   /   ⌃⇧3 : 열 구분 = 탭(엑셀·시트용)
// ============================================================

// ---- 캡처 → OCR → 클립보드 ----
func captureAndCopy(tab: Bool) {
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("teleclip-\(UUID().uuidString).png")

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-i", "-o", "-x", tmpURL.path]   // 인터랙티브, 그림자 없음, 셔터음 없음
    do { try task.run(); task.waitUntilExit() } catch { return }

    guard FileManager.default.fileExists(atPath: tmpURL.path),
          let img = NSImage(contentsOf: tmpURL),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return }   // Esc로 취소 등
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false   // ID·숫자·이메일은 사전 보정이 오히려 글자를 바꿔버림
    req.recognitionLanguages = ["ko-KR", "en-US"]

    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    guard (try? handler.perform([req])) != nil,
          let obs = req.results, !obs.isEmpty else { return }

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
    let text = rows
        .map { $0.sorted { $0.minX < $1.minX }.map { $0.text }.joined(separator: colSep) }
        .joined(separator: "\n")

    DispatchQueue.main.async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
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
            let tab = (hkID.id == 2)
            DispatchQueue.global().async { captureAndCopy(tab: tab) }
            return noErr
        }, 1, &spec, nil, nil)

        let mods = UInt32(controlKey | shiftKey)
        add(id: 1, key: UInt32(kVK_ANSI_2), mods: mods)  // ⌃⇧2 → 공백
        add(id: 2, key: UInt32(kVK_ANSI_3), mods: mods)  // ⌃⇧3 → 탭
    }

    private func add(id: UInt32, key: UInt32, mods: UInt32) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x54_45_4C_43), id: id)  // 'TELC'
        RegisterEventHotKey(key, mods, hkID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

// ---- 메뉴바 앱 ----
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var loginMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Teleclip")
            if btn.image == nil { btn.title = "✂︎" }
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "캡처 → 클립보드 (공백)   ⌃⇧2", action: #selector(capSpace), keyEquivalent: "")
        menu.addItem(withTitle: "캡처 → 클립보드 (탭)     ⌃⇧3", action: #selector(capTab), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        let login = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(login)
        loginMenuItem = login
        updateLoginState()

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "종료", action: #selector(quit), keyEquivalent: "q")
        for it in menu.items { it.target = self }
        statusItem.menu = menu

        HotKeys.shared.register()
    }

    @objc func capSpace() { DispatchQueue.global().async { captureAndCopy(tab: false) } }
    @objc func capTab()   { DispatchQueue.global().async { captureAndCopy(tab: true) } }
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

    func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Teleclip"
        a.informativeText = msg
        a.runModal()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // Dock 아이콘 없음, 메뉴바에만 표시
let delegate = AppDelegate()
app.delegate = delegate
app.run()
