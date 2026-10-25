// TypedHistory（確定した文章を覚える仕組み）の動きを確かめる
import Core
import Foundation

var failures = 0
@MainActor func check(_ name: String, _ actual: String?, _ expected: String?) {
    let ok = actual == expected
    if !ok { failures += 1 }
    print("\(ok ? "OK " : "NG ") \(name): \(actual ?? "nil")\(ok ? "" : "（期待: \(expected ?? "nil")）")")
}
let h = TypedHistory()
let t0 = Date()
h.append("前立腺がんの患者。", app: "notion", now: t0)
h.append("\n", app: "notion", now: t0)
check("覚えた文章", h.text(app: "notion", now: t0), "前立腺がんの患者。\n")
check("アプリが何も返さない", TypedHistory.merge(fromClient: nil, history: h.text(app: "notion", now: t0), maxCount: 40), "前立腺がんの患者。\n")
check("アプリが空文字を返す", TypedHistory.merge(fromClient: "", history: h.text(app: "notion", now: t0), maxCount: 40), "前立腺がんの患者。\n")
h.append("膀胱", app: "notion", now: t0)
check("アプリの文章が末尾と一致→前に伸ばす", TypedHistory.merge(fromClient: "膀胱", history: h.text(app: "notion", now: t0), maxCount: 40), "前立腺がんの患者。\n膀胱")
check("アプリの文章が食い違う→アプリを優先", TypedHistory.merge(fromClient: "全く別の文", history: h.text(app: "notion", now: t0), maxCount: 40), "全く別の文")
h.deleteBackward(app: "notion", now: t0)
check("削除キー", h.text(app: "notion", now: t0), "前立腺がんの患者。\n膀")
check("ほかのアプリとは別", h.text(app: "chrome", now: t0), "")
check("3分打たなければ忘れる", h.text(app: "notion", now: t0.addingTimeInterval(200)), "")
h.append("前置き", app: "x", now: t0)
h.noteCompositionStart(app: "x", location: 10)
h.append("あいう", app: "x", now: t0)
h.checkCursor(app: "x", location: 13)
check("打ち始め10＋3文字＝13で続ける→覚えたまま", h.text(app: "x", now: t0), "前置きあいう")
h.checkCursor(app: "x", location: 3)
check("カーソルが飛んだ→忘れる", h.text(app: "x", now: t0), "")
h.append("位置不明", app: "z", now: t0)
h.checkCursor(app: "z", location: 99)
check("位置が分からないうちは忘れない", h.text(app: "z", now: t0), "位置不明")
h.noteCompositionStart(app: "n", location: 0)
h.append("一行目", app: "n", now: t0)
h.noteCompositionStart(app: "n", location: 0)
h.append("。", app: "n", now: t0)
h.appendNewline(app: "n", now: t0)
h.checkCursor(app: "n", location: 0)
check("改行のあと（Notion の新しいブロックで位置0）→覚えたまま", h.text(app: "n", now: t0), "一行目。\n")
h.noteCompositionStart(app: "e", location: 5)
h.append("😀", app: "e", now: t0)
h.checkCursor(app: "e", location: 7)
check("絵文字は UTF-16 で2つ分", h.text(app: "e", now: t0), "😀")
h.append(String(repeating: "あ", count: 150), app: "y", now: t0)
check("100文字まで", String(h.text(app: "y", now: t0).count), "100")
// 選んだ文の前の文章を、覚えている文章から補う
check("選んだ文が最後に打った部分→その手前を返す", TypedHistory.textBefore(selection: "膀胱鏡の所見をまとめて", history: "前立腺がんの患者。\n膀胱鏡の所見をまとめて"), "前立腺がんの患者。\n")
check("最後に改行があっても同じ", TypedHistory.textBefore(selection: "膀胱鏡の所見をまとめて", history: "前立腺がんの患者。\n膀胱鏡の所見をまとめて\n"), "前立腺がんの患者。\n")
check("昔の段落を選んだ→使わない", TypedHistory.textBefore(selection: "前立腺がんの患者。", history: "前立腺がんの患者。\n膀胱鏡の所見をまとめて"), nil)
check("覚えているのが選んだ文だけ→使わない", TypedHistory.textBefore(selection: "メールにして", history: "メールにして"), nil)
check("記憶が空→使わない", TypedHistory.textBefore(selection: "メールにして", history: ""), nil)
// 接続先の決まり（この Mac の中だけ）
for (url, expected) in [
    ("http://127.0.0.1:11434/v1/chat/completions", true),
    ("http://localhost:1234/v1/chat/completions", true),
    ("http://[::1]:11434/v1/chat/completions", true),
    ("https://api.openai.com/v1/chat/completions", false),
    ("http://127.0.0.1.example.com/v1", false),
    ("http://localhost.example.com/v1", false),
    ("http://user@127.0.0.1@example.com/", false),
    ("http://0.0.0.0:11434/", false),
    ("http://192.168.1.10:11434/", false),
    ("file:///etc/hosts", false),
] {
    check("接続先 \(url)", String(LocalEndpointPolicy.isAllowed(URL(string: url)!)), String(expected))
}
// 転送（リダイレクト）に従わないこと: 引数でこの Mac の中の試験用サーバーの URL を渡す
if CommandLine.arguments.count > 1, let url = URL(string: CommandLine.arguments[1]) {
    let (_, response) = try await LocalEndpointPolicy.session.data(for: URLRequest(url: url))
    check("外部への転送に従わない（307 のまま返る）", String((response as? HTTPURLResponse)?.statusCode ?? -1), "307")
}
print(failures == 0 ? "すべてOK" : "NG \(failures) 件")
exit(failures == 0 ? 0 : 1)
