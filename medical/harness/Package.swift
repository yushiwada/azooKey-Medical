// swift-tools-version: 6.1
// azooKey Medical の検証用ツール
//   live-harness: IME の中核（Core の SegmentsManager）を1打鍵ずつ動かし、ライブ変換・予測・処理時間を出す
//   dict-builder: 読みと表記の TSV から、変換エンジンが読む辞書（user.louds など）を作る
//   history-test: 打った文章を覚える仕組み（TypedHistory）と接続先の決まりのテスト
//   ai-client-test: IME と同じ呼び出しで、この Mac の LLM サーバーから返事が取れるかを確かめる
//   model-list-test: モデルの一覧・読み込み状態・入れる機能を、この Mac の Ollama で確かめる
import PackageDescription

let package = Package(
    name: "LiveHarness",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Core"),
        // azooKey-Desktop の Core と同じ版を使う
        .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", revision: "04ce2ec3afe2bd6f92fcae1dc15a2357d332c27a", traits: ["Zenzai"])
    ],
    targets: [
        .executableTarget(
            name: "live-harness",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter")
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .executableTarget(
            name: "ai-client-test",
            dependencies: [.product(name: "Core", package: "Core")],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .executableTarget(
            name: "model-list-test",
            dependencies: [.product(name: "Core", package: "Core")],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .executableTarget(
            name: "history-test",
            dependencies: [.product(name: "Core", package: "Core")],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .executableTarget(
            name: "dict-builder",
            dependencies: [
                .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter"),
                .product(name: "SwiftUtils", package: "AzooKeyKanaKanjiConverter")
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        )
    ]
)
