# 第三者の著作物と出典

azooKey Medical は、次の著作物を使っています。各ライセンスの全文は [licenses/](licenses/) にあり、配布用の zip には、これをつなげた `THIRD_PARTY_NOTICES.txt` が入ります。版は 2026-10-24 にこのリポジトリのビルドで確かめたものです。

## アプリ（azooKeyMac.app）に入っているもの

| 名前 | 使い方 | ライセンス | 入手元 |
|---|---|---|---|
| azooKey-Desktop | このリポジトリの元・アプリ本体 | MIT（Copyright (c) 2025 Miwa Keita） | https://github.com/azooKey/azooKey-Desktop （v0.1.4、f0b6afd） |
| AzooKeyKanaKanjiConverter | 変換エンジン | MIT（Copyright (c) 2023 Miwa / Ensan） | https://github.com/azooKey/AzooKeyKanaKanjiConverter （04ce2ec） |
| azooKey_dictionary_storage | 変換エンジンの辞書 | Apache License 2.0 | https://github.com/ensan-hcl/azooKey_dictionary_storage |
| azooKey_emoji_dictionary_storage | 絵文字の辞書 | リポジトリにライセンスの表記なし。元データは mozc（BSD 3-Clause）と Unicode（Unicode License v3） | https://github.com/ensan-hcl/azooKey_emoji_dictionary_storage |
| zenz-v3.2-small（gguf、Q5_K_M） | 変換AIのモデル（ソースからビルドしたとき） | Apache License 2.0（配布元の表記）。ファイルの中の情報からは、ku-nlp/gpt2-small-japanese-char を元にしたモデルと読める | https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf |
| zenz-v3.2-small を医療の文章で追加学習したモデル（gguf、Q5_K_M） | 変換AIのモデル（配布用の zip。下の「配布用の zip の変換AIのモデル」） | CC BY-SA 4.0 | https://github.com/yushiwada/azooKey-Medical の Releases |
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
- 誤字、読みの合わない組、語の断片、助詞などの付いた語、元の辞書で候補に出せる語を除きました。強く効かせる版（strong）では、よく使う語と同じ短い読みのまれな語も除きました。
- 変換エンジンの辞書の形式に変換しました。

アプリの中の `medical_dictionary/NOTICE.txt` にも、同じ内容の表示を置いています。辞書の作り方の記録（入力したファイルの sha256 など）は `medical_dictionary/BUILD_INFO` にあります。

## 配布用の zip の変換AIのモデル

Releases で配る zip には、変換AIのモデルとして、zenz-v3.2-small を医療の文章で追加学習したモデル（`zenz-v3.2-small-medical-P2g30-a050-Q5_K_M.gguf`、sha256 `505247bc08527866a34fb4f584e9657084d5ff8f1e40b26fd580f0b7f6807a54`）を入れています。同じファイルを Releases に単独でも置いています。ソースからビルドしたアプリには入りません。

ライセンスは CC BY-SA 4.0（https://creativecommons.org/licenses/by-sa/4.0/deed.ja ）です。学習に使った一般の文に、CC BY-SA 4.0 の Wikipedia 日本語版に由来する部分が含まれるためです。このモデルは無保証で提供されます。

元のモデル:

- zenz-v3.2-small（Miwa Keita）https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf 。配布元の表記は Apache License 2.0 です
- その元の ku-nlp/gpt2-small-japanese-char（ku-nlp、CC BY-SA 4.0）https://huggingface.co/ku-nlp/gpt2-small-japanese-char

学習に使った文書と出典の表示:

- 厚生労働省ホームページの文書（厚生労働省ホームページの利用規約〔公共データ利用規約 第1.0版（PDL1.0）に準拠〕 https://www.mhlw.go.jp/chosakuken/index.html ）
  - 「重篤副作用疾患別対応マニュアル」（厚生労働省）（https://www.mhlw.go.jp/stf/seisakunitsuite/bunya/kenkou_iryou/iyakuhin/topics/tp061122-1.html と、そこから開く19の区分のページ）を加工して作成
  - 「指定難病の概要、診断基準等」（厚生労働省）（https://www.mhlw.go.jp/stf/newpage_53881.html ）を加工して作成
  - 「医師国家試験問題および正答について」（厚生労働省）（第110回・第113〜120回のページ。URL の一覧は `licenses/23-zenz-v3.2-small-medical.txt`）を加工して作成。問題冊子の本文だけを使い、画像と正答は使っていません
  - 加工の内容: PDF から本文を取り出し、ページ番号・振り仮名・表・名簿・症例の報告・文献などを除き、短く切り分けて読みを付け、変換の例にしました。このモデルは azooKey Medical の作者が作ったもので、厚生労働省が作ったものでも、内容を保証するものでもありません
- KAKEN（科学研究費助成事業データベース、国立情報学研究所 https://kaken.nii.ac.jp/ ）の研究課題の概要のうち、医療の課題として選んだ16,754課題。LLM-jp Corpus v3（LLM-jp、CC BY 4.0、https://gitlab.llm-jp.nii.ac.jp/datasets/llm-jp-corpus-v3 ）の `ja/kaken/kaken-v1.jsonl.gz` から取りました。同じ文の繰り返しと、1人の患者さんの経過を書いた文を除いて使いました
- 一般の文: zenz-v2.5-dataset（Miwa Keita）https://huggingface.co/datasets/Miwa-Keita/zenz-v2.5-dataset の一部。Wikipedia 日本語版（2024年2月の版、Wikipedia の執筆者）に由来する部分は CC BY-SA 4.0、llm-jp-corpus v3 の Common Crawl に由来する部分は ODC-BY 1.0（https://opendatacommons.org/licenses/by/1-0/ ）と Common Crawl の利用規約（https://commoncrawl.org/terms-of-use ）のもとで提供されています
- 医療の語の読みと、変換AIに渡す手がかりの語: JMED-DICT mini（v1.1.2、奈良先端科学技術大学院大学 JMED-DICT 作業班、CC BY 4.0）のうち、出典に万病辞書か百薬辞書を含む語だけ。日本医学会 医学用語辞典（JAMSMDIC）だけを出典とする語は使っていません
- 読みを付けるのに使った道具: Sudachi（sudachipy 0.7.0）と SudachiDict core（どちらも Apache License 2.0）、azooKey の辞書（azooKey_dictionary_storage、Apache License 2.0）

加えた変更: 上の文章を短く切り分けて読みを付け、変換の例を48万組作りました。この例で zenz-v3.2-small を LoRA で追加学習し、学習で変わった分を半分の倍率で元の重みに足して、Q5_K_M に量子化しました。学習データと評価の問題は配っていません。文書の取得日は 2026-10-27 です。

同じ内容は `licenses/23-zenz-v3.2-small-medical.txt` にもあり、このモデルを入れた zip の `THIRD_PARTY_NOTICES.txt` に入ります。
