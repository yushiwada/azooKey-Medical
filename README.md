# azooKey Medical

医療の文章を打ちやすくした、Mac 用の日本語入力です。オープンソースの日本語入力 [azooKey](https://github.com/azooKey/azooKey-Desktop)（Mac 版）をもとに個人が作った非公式の派生版で、本家の azooKey とは関係がありません。変換はすべて Mac の中で行い、打った文章を外部に送りません。

> **注意**　アルファ版の試作です。医療用語の変換は誤ることがあるので、診療録など正式な記録では、確定した文字を必ず読み直してください。医療機器ではありません。

## できること

- **医療用語の辞書を足しています。** 病名・手術・解剖・薬・症状・検査などの語のうち、元の azooKey では候補に出てこないものを約20万語入れました。たとえば「すいじんしょう」で「水腎症」、「かんけつはこう」で「間欠跛行」が出ます。
- **ローマ字で打った英単語は、英字のまま残ります。** 日本語入力のまま「kinoucomputerwotukatta」と打つと「昨日computerを使った」に変換されます。「tenki」のようにかなになる綴りは、今までどおりかなとして扱います。CT・MRI・CRP など、よく使う医療の略語は、小文字で打っても大文字で出ます。設定の「ローマ字で打った英単語を自動で英字にする」で切れます（最初は ON）。
- **配布用の zip の変換AIは、医療の文章で追加学習したモデルです。** 学習に使わなかった医療の文章から作った400問では、答えが1位に出た数が、元のモデルの245問から318問に増えました。
- **前の文章を手がかりに、同じ読みの語を選び分けます。** 「虫に刺されて足が」に続けて「はれた」と打つと「腫れた」に、「雨がやんで空が」に続けると「晴れた」になります。選ぶのは azooKey の変換AI（Zenzai）で、元の azooKey が見ている同じ行の文章に加えて、前の行も手がかりにします。
- **前の文章を入力ソフトに渡さないアプリでも、文脈を使えます。** Notion や Chrome のようなアプリのために、自分が打った文章を入力欄ごとに直近100文字だけメモリに覚えます。ファイルには保存せず、入力欄を離れると消します。
- **選んだ文を AI への指示として実行します。** 「明日の打ち合わせの時間を確認するメールを書いて」と打ってその文を選び、Option + Return を押すと、AI の返事に置き換わります。使う AI は、Mac に入っている Apple Intelligence か、この Mac の中で動かす LLM（Ollama など）から選びます。
- **Caps Lock で日本語と英字を切り替えられます**（システム設定でオンにしたとき）。

ノートのタイトルとカーソルの後ろの文章も、変換の手がかりに渡します（実験的）。

## 評価

作者が作った問題で、答えが1位に出た数を数えました。

| 問題 | 結果 |
|---|---|
| 医療用語 105問 | 辞書なし 84問 → 配布版の辞書あり 88問 |
| 同音異義語 57問 | 辞書だけ 58% → 変換AIを使う 77% → 前の文章も渡す 95% |
| 普段の文 30問 | 辞書を入れても 28問のまま（悪くならない） |

問題の数が少なく、辞書の作り方もこれらの問題を見ながら決めたので、初めて見る文章ではこれより下がる見込みです。医療用語105問の 84→88 は、偶然の差と区別できません。くわしくは [medical/README.md](medical/README.md) を見てください。

配布用の zip の変換AI（追加学習したモデル）は、元のモデルと次のように比べました（配布版の辞書あり）。

| 問題 | 元のモデル → 追加学習したモデル |
|---|---|
| このリポジトリの問題 302問（上の問題を含む8種類） | 264問 → 281問 |
| AJIMEE-Bench 200問（azooKey の作者が公開している日本語入力の評価用の問題） | 170問 → 172問 |
| 医療の文章 400問（学習に使わなかった厚生労働省と科研費の文書から作った問題） | 245問 → 318問 |

医療の文章400問は、学習に使った文書と同じ種類の文書から作ったので、ほかの医療の文章ではこれより下がる見込みです。AJIMEE-Bench の差は、偶然の差と区別できません。作り方と評価のくわしいことは [medical/README.md](medical/README.md#配布用の-zip-の変換ai) にあります。

## 使える Mac と入れ方

Apple Silicon の Mac と macOS 26 で使えます（作者は macOS 26.5 で確認しました）。sudo と Apple Developer への登録は要りません。

**Releases の zip で入れる（ビルドは要りません）:** [Releases](https://github.com/yushiwada/azooKey-Medical/releases) から zip と `.zip.sha256` のファイルを落とします。ターミナルでそのフォルダに移り、`shasum -a 256 -c azooKey-Medical-*.zip.sha256` を実行して「OK」と出ることを確かめます。zip を開いてできたフォルダの中の `install.command` を、ターミナルで `bash <そのフォルダ>/install.command` として実行します。zip には、医療用語の辞書と、追加学習した変換AIのモデルが入っています。

**ソースからビルドして入れる:** Xcode 26.1 以上と Git LFS が要ります。

```bash
git clone --recursive https://github.com/yushiwada/azooKey-Medical.git
cd azooKey-Medical
bash medical/scripts/build_install.sh
```

ソースからビルドすると、変換AIのモデルは元の azooKey と同じ zenz-v3.2-small です。追加学習したモデルを使うときは、Releases から gguf のファイルを落とし、`ZENZ_GGUF=<gguf のパス> bash medical/scripts/build_install.sh` と実行します。医療用語の辞書は、ビルドの前に作っておくと一緒に入ります（30分ほどかかります）。

どちらの場合も、入れたら、システム設定 → キーボード →「入力ソース」の「編集…」→「+」→ 日本語 →「azooKey Medical (日本語)」を追加します。辞書の作り方と、AI の準備（Ollama とおすすめのモデル）は [medical/README.md](medical/README.md) にあります。

## Mac の中に残るもの・外に出るもの

入力ソフトからは何も送りません。ローマ字で打った英単語の判定も、Mac に入っている英語の綴りの辞書で行います。ネット通信は、この Mac の中の LLM に接続するときだけ使い、接続先が 127.0.0.1・localhost・::1 でなければ送る前に断ります。Ollama の「クラウドのモデル」も使いません。変換の学習データやユーザ辞書などは、暗号化せずに Mac の中に保存されます（一覧は [medical/README.md](medical/README.md)）。患者さんの情報を含む文章では、Mac の中の Apple のモデルで処理する Apple Intelligence がいちばん安全です。AI の返事も誤ることがあるので、必ず読み直してください。

## ライセンスと出典

元の azooKey と変換エンジンは MIT、変換AIのモデル（zenz-v3.2-small）は Apache License 2.0 です。配布用の zip に入れた追加学習したモデルは CC BY-SA 4.0 です。学習には、厚生労働省の公開文書、科研費の研究課題の概要（KAKEN）、zenz-v2.5-dataset の一部を使いました。医療用語の辞書は JMED-DICT mini（奈良先端科学技術大学院大学、CC BY 4.0）をもとに作り、配布版には、出典に万病辞書か百薬辞書（どちらも CC BY 4.0）を含む語だけを入れています。すべての一覧は [medical/NOTICE.md](medical/NOTICE.md) にあります。

---

以下は元の azooKey の説明です。この中の「リリース版インストール」や Homebrew で入るのは元の azooKey で、azooKey Medical ではありません。

# azooKey on macOS

[azooKey](https://github.com/ensan-hcl/azooKey)のmacOS版です。高精度なニューラルかな漢字変換エンジン「Zenzai」を導入した、オープンソースの日本語入力システムです。

**現在アルファ版のため、動作は一切保証できません**。

## 動作環境

macOS 15で動作確認しています。macOS 14およびmacOS 26でも利用できますが、動作は検証していません。

## リリース版インストール

[Releases](https://github.com/ensan-hcl/azooKey-Desktop/releases)から`.pkg`ファイルをダウンロードして、インストールしてください。

その後、以下の手順で利用できます。

- macOSからログアウトし、再ログイン
- 「設定」>「キーボード」>「入力ソース」を編集>「+」ボタン>「日本語」>azooKeyを追加>完了
- メニューバーアイコンからazooKeyを選択

### Install with Homebrew
または、Homebrewを用いてインストールすることもできます。

```bash
brew install azooKey
```
この場合も上記のログアウト・再ログイン後の設定は必要です。
アップグレードは以下のコマンドで実行できますが、再起動が必要になることがあります。

```bash
brew upgrade azooKey
```

## コミュニティ

azooKey on macOSの開発に参加したい方、使い方に質問がある方、要望や不具合報告がある方は、ぜひ[azooKeyのDiscordサーバ](https://discord.gg/dY9gHuyZN5)にご参加ください。


### azooKey on macOSを支援する

GitHub Sponsorsをご利用ください。


## 機能

* ニューラルかな漢字変換システム「Zenzai」による高精度な変換
  * プロフィールプロンプト機能
  * 履歴学習機能
  * ユーザ辞書機能
  * 個人最適化システム「[Tuner](https://github.com/azooKey/Tuner)」との連携機能
* LLMによる「いい感じ変換」機能
* ライブ変換
* AZIKのネイティブサポート


## 開発ガイド

コントリビュート歓迎です！！

### 必要な環境
* macOS 15+
* Xcode 26.1+
* Git LFS（必須。Hugging Face上のsubmoduleがLFSを利用しているため、未導入だとモデル重みが取得できません）
* SwiftLint

```bash
brew install git-lfs swiftlint
git lfs install
```

### 開発版のビルド・デバッグ

#### 1. クローン

submoduleにzenzのgguf重みと言語モデル（`.marisa`）が含まれるため、`--recursive`と Git LFS の有効化が必須です。

```bash
git lfs install        # 未実行の場合のみ
git clone https://github.com/azooKey/azooKey-Desktop --recursive
cd azooKey-Desktop
```

既にcloneしていてsubmoduleやLFSが揃っていない場合は以下を実行してください。

```bash
git submodule update --init
git -C azooKeyMac/Resources/zenz-v3.1-small-gguf lfs pull
git -C azooKeyMac/Resources/base_n5_lm lfs pull
```

重みファイルが正しく取得できているか、サイズで確認できます（数十MB以上あればLFSの実体、134B程度ならポインタのままです）。

```bash
ls -lh azooKeyMac/Resources/zenz-v3.1-small-gguf/ggml-model-Q5_K_M.gguf
```

#### 2. 署名の設定（初回のみ）

`install.sh` はアーカイブビルドを行うため、Xcode上で署名設定が通っている必要があります。Apple Developer Programに加入していない場合は、Personal Teamでの署名に切り替えてください。

* `azooKeyMac.xcodeproj` を Xcode で開く
* azooKeyMac ターゲット → Signing & Capabilities で Team を自身の Personal Team に変更
* リポジトリ内のバンドルID（`dev.ensan.inputmethod.azooKeyMac` など）を、自身の所有するプレフィックスに一括置換（例: `dev.yourname.inputmethod.azooKeyMac`）

#### 3. ビルド＆インストール

```bash
./install.sh
```

`.pkg`によるインストールと同等の状態になります。その後、上記の「リリース版インストール」の手順（ログアウト→入力ソース追加）を行ってください。

開発中はazooKeyのプロセスをkillすることで最新版を反映することが出来ます。また、必要に応じて入力ソースからazooKeyを削除して再度追加する、macOSからログアウトして再ログインするなど、リセットが必要になる場合があります。

### 開発時のトラブルシューティング

`install.sh`でビルドが成功しない場合、以下をご確認ください。

* 署名エラーで失敗する場合は、上記「署名の設定」が完了しているかを確認してください（Team変更とバンドルID置換の両方が必要です）
* 「Packages are not supported when using legacy build locations, but the current project has them enabled.」と表示される場合は[https://qiita.com/glassmonkey/items/3e8203900b516878ff2c](https://qiita.com/glassmonkey/items/3e8203900b516878ff2c)を参考に、Xcodeの設定をご確認ください
* Xcode 26.0ではビルドできない可能性があります。Xcode 16系または26.1以降をご利用ください。

変換精度がリリース版に比べて悪いと感じた場合、以下をご確認ください。
* Git LFSが導入されていない環境では、重みファイルがローカル環境に落とせていない場合があります。`azooKeyMac/Resources/zenz-v3.1-small-gguf/ggml-model-Q5_K_M.gguf` が数十MB以上あるかを確認し、ポインタのままであれば `git -C azooKeyMac/Resources/zenz-v3.1-small-gguf lfs pull` を実行してください

### pkgファイルの作成
`pkgbuild.sh`によって配布用のdmgファイルを作成できます。`build/azooKeyMac.app` としてDeveloper IDで署名済みの.appを配置してください。

### v1.0リリースに向けて
[meta: v1.0のリリースに向けたロードマップ（#181）](https://github.com/azooKey/azooKey-Desktop/issues/181)をご覧ください．

## Community Forks

### [fcitx5-hazkey](https://github.com/7ka-Hiira/fcitx5-hazkey)
@7ka-Hiira さんによるLinux系OS向けのクライアント実装です。

### [azooKey-Windows](https://github.com/fkunn1326/azooKey-Windows)
@fkunn1326 さんによるWindows向けクライアント実装です。

### [azoo-key-skkserv](https://github.com/gitusp/azoo-key-skkserv)
@gitusp さんによるSKKクライアント向けのSKKサーバ実装です。macOS向けGUIアプリケーションを含みます。

## Reference

Thanks to authors!!

* https://mzp.hatenablog.com/entry/2017/09/17/220320
* https://www.logcg.com/en/archives/2078.html
* https://stackoverflow.com/questions/27813151/how-to-develop-a-simple-input-method-for-mac-os-x-in-swift
* https://mzp.booth.pm/items/809262

## Acknowledgement
本プロジェクトは情報処理推進機構(IPA)による[2024年度未踏IT人材発掘・育成事業](https://www.ipa.go.jp/jinzai/mitou/it/2024/koubokekka.html)の支援を受けて開発を行いました。
