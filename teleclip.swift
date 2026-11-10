import Foundation
import AppKit
import Vision

// Teleclip: 화면 영역을 드래그로 선택 → Vision OCR(한/영) → macOS 클립보드에 복사.
// VDI(Omnissa Horizon) 화면처럼 '그림'으로만 보이는 텍스트를 가져오기 위한 도구.

func die(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

// 1) Apple 내장 screencapture로 인터랙티브 영역 캡처.
let tmpURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("teleclip-\(UUID().uuidString).png")

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
// -i 인터랙티브 선택, -o 창 그림자 제거, -x 셔터음 끔
task.arguments = ["-i", "-o", "-x", tmpURL.path]
do {
    try task.run()
    task.waitUntilExit()
} catch {
    die("screencapture 실행 실패: \(error)")
}

// 사용자가 Esc로 취소하면 파일이 생기지 않음 → 조용히 종료.
guard FileManager.default.fileExists(atPath: tmpURL.path),
      let nsImage = NSImage(contentsOf: tmpURL),
      let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    exit(0)
}
defer { try? FileManager.default.removeItem(at: tmpURL) }

// 열 구분자: 기본은 공백, --tab 이면 탭(엑셀/시트 붙여넣기용).
let useTab = CommandLine.arguments.contains("--tab")
let colSep = useTab ? "\t" : " "

// 2) Vision OCR.
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false   // ID·숫자·이메일은 사전 보정이 오히려 글자를 바꿔버림
request.recognitionLanguages = ["ko-KR", "en-US"]

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
do {
    try handler.perform([request])
} catch {
    die("OCR 실패: \(error)")
}

guard let observations = request.results, !observations.isEmpty else {
    die("인식된 텍스트가 없습니다.")
}

// 인식 조각을 (텍스트, 세로중심, 가로시작, 높이)로 변환. Vision 좌표계는 원점이 좌하단(y가 위로 증가).
struct Piece { let text: String; let midY: Double; let minX: Double; let height: Double }
let pieces: [Piece] = observations.compactMap { o in
    guard let s = o.topCandidates(1).first?.string else { return nil }
    let b = o.boundingBox
    return Piece(text: s, midY: Double(b.midY), minX: Double(b.minX), height: Double(b.height))
}

// 위→아래로 정렬한 뒤, 세로 중심이 비슷한 조각들을 '같은 행'으로 묶는다.
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

// 각 행 안에서는 가로 순서로 이어 붙이고, 행끼리는 개행으로 연결.
let lines = rows.map { row in
    row.sorted { $0.minX < $1.minX }.map { $0.text }.joined(separator: colSep)
}
let text = lines.joined(separator: "\n")

// 3) 클립보드에 쓰기.
let pb = NSPasteboard.general
pb.clearContents()
pb.setString(text, forType: .string)

// 확인용 출력 (단축키로 백그라운드 실행 시엔 무시됨).
print(text)
