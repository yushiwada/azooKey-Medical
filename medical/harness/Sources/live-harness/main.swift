// IME の中核（Core の SegmentsManager）を、実際のキー入力と同じく1文字ずつ動かし、
// ライブ変換の表示・予測候補・1打鍵あたりの処理時間を出す。
// 使い方: live-harness <ケースのTSV>（各行「左文脈<TAB>ローマ字[<TAB>後ろの文章<TAB>文書の先頭]」）
import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

final class FixedLeftContext: SegmentManagerDelegate {
    let text: String
    let right: String
    let head: String
    init(_ text: String, right: String = "", head: String = "") {
        self.text = text
        self.right = right
        self.head = head
    }
    func getLeftSideContext(maxCount: Int) -> String? {
        String(text.suffix(maxCount))
    }
    func getRightSideContext(maxCount: Int) -> String? {
        right.isEmpty ? nil : String(right.prefix(maxCount))
    }
    func getDocumentHead(maxCount: Int) -> String? {
        head.isEmpty ? nil : String(head.prefix(maxCount))
    }
}

@MainActor
func run(cases: [(left: String, romaji: String, right: String, head: String)]) {
    let memoryDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("live-harness/memory", isDirectory: true)
    try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
    let manager = SegmentsManager(
        kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: memoryDir,
        containerURL: nil
    )
    var allTimes: [Double] = []
    for (index, c) in cases.enumerated() {
        let context = FixedLeftContext(c.left, right: c.right, head: c.head)
        manager.delegate = context
        manager.activate()
        var times: [Double] = []
        var shown = ""
        for ch in c.romaji {
            let start = DispatchTime.now().uptimeNanoseconds
            manager.insertAtCursorPosition(String(ch), inputStyle: .roman2kana)
            shown = manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let prediction = manager.requestPredictionCandidates().first?.displayText ?? "-"
        let sorted = times.sorted()
        // 1件目はモデルの読み込みを含むので集計から外す
        if index > 0 { allTimes += times }
        print("文脈「\(c.left)」 後ろ「\(c.right)」 先頭「\(c.head.replacingOccurrences(of: "\n", with: "⏎"))」 入力 \(c.romaji)")
        print("  ライブ変換: \(shown)   予測: \(prediction)")
        print(String(format: "  1打鍵: 中央値 %.1f ms / 最大 %.1f ms（%d 打鍵）", sorted[sorted.count / 2], sorted.last ?? 0, times.count))
        manager.stopComposition()
        manager.deactivate()
    }
    let sorted = allTimes.sorted()
    if !sorted.isEmpty {
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print(String(format: "全体（1件目を除く %d 打鍵）: 中央値 %.1f ms / 95%%点 %.1f ms / 最大 %.1f ms", sorted.count, sorted[sorted.count / 2], p95, sorted.last!))
    }
}

let path = CommandLine.arguments.dropFirst().first ?? "cases.tsv"
guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("ケースのファイルが読めない: \(path)")
    exit(1)
}
let cases = raw.split(separator: "\n").compactMap { line -> (String, String, String, String)? in
    let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map { String($0).replacingOccurrences(of: "\\n", with: "\n") }
    guard cols.count >= 2 else { return nil }
    return (cols[0], cols[1], cols.count > 2 ? cols[2] : "", cols.count > 3 ? cols[3] : "")
}
MainActor.assumeIsolated {
    run(cases: cases.map { (left: $0.0, romaji: $0.1, right: $0.2, head: $0.3) })
}
