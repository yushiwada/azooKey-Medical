// IME と同じ呼び出し（AIClient.sendTextTransformRequest、ローカルLLM）で、この Mac の LLM サーバーから返事が取れるかを確かめる
// 使い方: ai-client-test <モデル名> [接続先]
import Core
import Foundation

let args = CommandLine.arguments
let model = args.count > 1 ? args[1] : LocalModelList.recommendedModel()
let endpoint = args.count > 2 ? args[2] : "http://127.0.0.1:11434/v1/chat/completions"
do {
    let models = try await LocalModelList.fetch(chatEndpoint: endpoint)
    print("入っているモデル: \(models)")
    let start = Date()
    let result = try await AIClient.sendTextTransformRequest(
        "次の指示を実行し、結果の本文だけを返してください。\n\n指示: 「様子を見ましょう」を、患者さんに伝わるやさしい言い方に言い換えて",
        backend: .openAI, modelName: model, apiKey: "local", apiEndpoint: endpoint
    )
    print(String(format: "返事（%.1f秒）: %@", Date().timeIntervalSince(start), result))
} catch {
    print("エラー: \(error.localizedDescription)")
}
// 外部の接続先は送る前に断ること
do {
    _ = try await AIClient.sendTextTransformRequest("テスト", backend: .openAI, modelName: model, apiKey: "local", apiEndpoint: "https://api.openai.com/v1/chat/completions")
    print("NG: 外部の接続先に送ってしまった")
} catch {
    print("外部の接続先: \(error.localizedDescription)")
}
