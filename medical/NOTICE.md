# 第三者の著作物と出典

azooKey Medical は、次の著作物を使っています。各ライセンスの全文は [licenses/](licenses/) にあり、配布用の zip には、これをつなげた `THIRD_PARTY_NOTICES.txt` が入ります。版は 2026-10-24 にこのリポジトリのビルドで確かめたものです。

## アプリ（azooKeyMac.app）に入っているもの

| 名前 | 使い方 | ライセンス | 入手元 |
|---|---|---|---|
| azooKey-Desktop | このリポジトリの元・アプリ本体 | MIT（Copyright (c) 2025 Miwa Keita） | https://github.com/azooKey/azooKey-Desktop （v0.1.4、f0b6afd） |
| AzooKeyKanaKanjiConverter | 変換エンジン | MIT（Copyright (c) 2023 Miwa / Ensan） | https://github.com/azooKey/AzooKeyKanaKanjiConverter （04ce2ec） |
| azooKey_dictionary_storage | 変換エンジンの辞書 | Apache License 2.0 | https://github.com/ensan-hcl/azooKey_dictionary_storage |
| azooKey_emoji_dictionary_storage | 絵文字の辞書 | リポジトリにライセンスの表記なし。元データは mozc（BSD 3-Clause）と Unicode（Unicode License v3） | https://github.com/ensan-hcl/azooKey_emoji_dictionary_storage |
| zenz-v3.2-small（gguf、Q5_K_M） | 変換AIのモデル | Apache License 2.0（配布元の表記）。ファイルの中の情報からは、ku-nlp/gpt2-small-japanese-char を元にしたモデルと読める | https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf |
| ku-nlp/gpt2-small-japanese-char のトークナイザ | 変換エンジンが使う文字の表 | CC BY-SA 4.0 | https://huggingface.co/ku-nlp/gpt2-small-japanese-char |
| base_n5_lm | 言語モデル（元の azooKey と同じく同梱） | 入手元にライセンスの表記なし | https://huggingface.co/Miwa-Keita/base_n5_lm |
| llama.cpp（xcframework、b4846） | 変換AIを動かす部品 | MIT（Copyright (c) 2023-2024 The ggml authors） | https://github.com/azooKey/llama.cpp |
| swift-collections・swift-algorithms・swift-numerics | 実行ファイルの中 | Apache License 2.0（Runtime Library Exception 付き） | https://github.com/apple |
| swift-crypto・swift-asn1 | 実行ファイルの中（swift-asn1 は依存として取得） | Apache License 2.0 | https://github.com/apple |
| ZIPFoundation | 実行ファイルの中 | MIT | https://github.com/weichsel/ZIPFoundation |
| SwiftyMarisa・marisa-trie | 実行ファイルの中 | BSD 2-Clause と LGPL 2.1 以降の二重ライセンス（BSD 2-Clause を選ぶ） | https://github.com/ensan-hcl/SwiftyMarisa ・ https://github.com/s-yata/marisa-trie |
| swift-tokenizers | 実行ファイルの中 | Apache License 2.0 | https://github.com/ensan-hcl/swift-tokenizers |
| Jinja | 実行ファイルの中 | MIT | https://github.com/johnmai-dev/Jinja |
| JMED-DICT mini（v1.1.2）の万病辞書・百薬辞書の部分 | 医療用語の辞書。リポジトリには含めず、作るたびに取得する | CC BY 4.0 | https://huggingface.co/datasets/sociocom/JMED-DICT_mini （a0f5c997113947bb1be6264eddfdbe5ed1da25a3） |
| Swift の実行時ライブラリ | Xcode が同梱するもの | Apache License 2.0（Runtime Library Exception 付き） | https://github.com/swiftlang/swift |

## アプリに含めないもの

- Ollama と LLM のモデル（Gemma 4 など）は、使う人がそれぞれ入れます。各配布元の条件に従ってください。
- Apple Intelligence は macOS の機能です。

## 医療用語の辞書の出典の表示

アプリに同梱する医療用語の辞書は、JMED-DICT mini（v1.1.2、奈良先端科学技術大学院大学 JMED-DICT 作業班）をもとに作成しました。ライセンスは CC BY 4.0（https://creativecommons.org/licenses/by/4.0/deed.ja ）です。配布元は、このデータを使って生じた問題について責任を負わないとしています。

配布版の辞書には、出典に次のどちらかを含む語だけを使っています。どちらも奈良先端科学技術大学院大学が CC BY 4.0 で公開している資料です。出典は、読みと表記の組ごとに確かめています。

- 万病辞書（MANBYO_202106）https://sociocom.naist.jp/manbyou-dic/
- 百薬辞書（HYAKUYAKU_202107。データの出典の列では HAKUYAKU と書かれています）https://sociocom.naist.jp/hyakuyaku-dic/

日本医学会 医学用語辞典（JAMSMDIC）は再利用を禁じているため、それだけを出典とする語は配布版に含めていません。JMED-DICT の配布元は、再配布するときは元の各資料の権利を確かめるよう求めています。

加えた変更は次のとおりです。

- 読みと表記だけを取り出しました。
- 誤字、語の断片、元の辞書で候補に出せる語を除きました。
- 変換エンジンの辞書の形式に変換しました。

アプリの中の `medical_dictionary/NOTICE.txt` にも、同じ内容の表示を置いています。辞書の作り方の記録（入力したファイルの sha256 など）は `medical_dictionary/BUILD_INFO` にあります。
