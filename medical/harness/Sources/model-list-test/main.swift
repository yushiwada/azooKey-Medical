// LocalModelList（モデルの一覧・読み込み状態・入れる機能）を、この Mac の Ollama で確かめる
// 使い方: swift run -c release model-list-test [--pull-installed]
//   --pull-installed を付けたときだけ、入っているモデルを入れ直す試験をする。
//   Ollama は版が同じなら登録を確かめるだけで終わるが、配布元でタグの中身が更新されていると、数GB をダウンロードしてしまう
import Core
import Foundation

let endpoint = "http://127.0.0.1:11434/v1/chat/completions"
let external = "https://example.com/v1/chat/completions"
nonisolated(unsafe) var failures = 0

func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "OK" : "NG")  \(name)")
    if !ok {
        failures += 1
    }
}

actor StatusRecorder {
    var statuses: [String] = []
    var lastFraction: Double?
    func add(_ status: String, _ fraction: Double?) {
        statuses.append(status)
        if let fraction {
            lastFraction = fraction
        }
    }
}

check("タグを省いた名前は latest を指す", LocalModelList.canonicalName("gemma4") == "gemma4:latest")
check("タグ付きの名前はそのまま", LocalModelList.canonicalName("gemma4:e4b-it-qat") == "gemma4:e4b-it-qat")
check("候補の名前に重複がない", Set(LocalModelList.catalog.map(\.name)).count == LocalModelList.catalog.count)
check("おすすめのモデルは候補に入っている", LocalModelList.catalog.contains { $0.name == LocalModelList.recommendedModel() })
check("8GB の Mac のおすすめは候補のメモリの目安に収まる", LocalModelList.catalog.first { $0.name == LocalModelList.recommendedModel(physicalMemory: 8 << 30) }.map { $0.memoryGB <= 8 } ?? false)

// 外のサーバーには何も送らない
check("外のサーバーは Ollama と見なさない", await LocalModelList.isOllama(chatEndpoint: external) == false)
check("外のサーバーの読み込み状態は取らない", await LocalModelList.loadedModels(chatEndpoint: external) == nil)
do {
    try await LocalModelList.pull(model: "gemma4:e2b-it-qat", chatEndpoint: external) { _, _ in }
    check("外のサーバーには pull を送らない", false)
} catch LocalOnlyError.nonLocalEndpoint {
    check("外のサーバーには pull を送らない", true)
} catch {
    check("外のサーバーには pull を送らない（別のエラー: \(error)）", false)
}

// この Mac の Ollama
check("この Mac の Ollama を見分ける", await LocalModelList.isOllama(chatEndpoint: endpoint))
let models = (try? await LocalModelList.fetch(chatEndpoint: endpoint)) ?? []
print("入っているモデル: \(models)")
let loaded = await LocalModelList.loadedModels(chatEndpoint: endpoint)
print("読み込み中のモデル: \(loaded ?? [])")
check("読み込み状態を取れる", loaded != nil)

// 入っているモデルを入れ直しても、ダウンロードせずに終わる（Ollama は登録情報を確かめるだけ）。
// タグの中身が更新されているとダウンロードが始まるので、--pull-installed を付けたときだけ試す
let pullInstalled = CommandLine.arguments.contains("--pull-installed")
if !pullInstalled {
    print("入っているモデルの入れ直しは試さない（試すときは --pull-installed を付ける）")
}
if pullInstalled, let installed = models.first {
    let recorder = StatusRecorder()
    let start = Date()
    do {
        try await LocalModelList.pull(model: installed, chatEndpoint: endpoint) { status, fraction in
            await recorder.add(status, fraction)
        }
        let seconds = Date().timeIntervalSince(start)
        let statuses = await recorder.statuses
        print("入れ直し: \(String(format: "%.1f", seconds))秒 状態=\(Array(Set(statuses)).sorted()) 進み具合=\(await recorder.lastFraction.map { String(format: "%.2f", $0) } ?? "なし")")
        check("入っているモデルの入れ直しは success で終わる", statuses.last == "success")
    } catch {
        check("入っているモデルの入れ直し（エラー: \(error.localizedDescription)）", false)
    }
}

// 存在しないモデルは、Ollama の理由つきのエラーになる
do {
    try await LocalModelList.pull(model: "azookey-medical-test/no-such-model:none", chatEndpoint: endpoint) { _, _ in }
    check("存在しないモデルはエラーになる", false)
} catch let error as LocalModelList.PullError {
    print("存在しないモデルのエラー: \(error.localizedDescription)")
    check("存在しないモデルは理由つきのエラーになる", true)
} catch {
    check("存在しないモデルは理由つきのエラーになる（別のエラー: \(error)）", false)
}

print(failures == 0 ? "すべて合格" : "不合格 \(failures) 件")
exit(failures == 0 ? 0 : 1)
