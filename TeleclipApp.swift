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
func startCapture(tab: Bool) {
    guard ScreenPermission.isGranted else {
        (NSApp.delegate as? AppDelegate)?.showPermissionAlert()
        return
    }
    DispatchQueue.global().async { captureAndCopy(tab: tab) }
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
            DispatchQueue.main.async { startCapture(tab: tab) }
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

        if !ScreenPermission.isGranted {
            NSApp.activate(ignoringOtherApps: true)
            showPermissionAlert()
        }
    }

    @objc func capSpace() { startCapture(tab: false) }
    @objc func capTab()   { startCapture(tab: true) }
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
app.setActivationPolicy(.accessory)   // Dock 아이콘 없음, 메뉴바에만 표시
let delegate = AppDelegate()
app.delegate = delegate
app.run()
