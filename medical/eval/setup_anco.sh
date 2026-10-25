#!/bin/bash
# 評価と辞書づくりに使う変換エンジンのコマンド（CliTool、通称 anco）を作る。
# azooKey-Desktop が使っているのと同じ版の AzooKeyKanaKanjiConverter を medical/build/ に取ってきて、
# 評価用の小さな変更（anco.patch）を当ててからビルドする。
#   anco.patch の中身: 評価で「話題」「プロフィール」を渡す／問題ごとに話題を指定する／追加辞書のフォルダを指定する
# 使い方: bash medical/eval/setup_anco.sh
set -euo pipefail
MED="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$MED/build/AzooKeyKanaKanjiConverter"
REV=04ce2ec3afe2bd6f92fcae1dc15a2357d332c27a
mkdir -p "$MED/build"
if [ ! -d "$DEST/.git" ]; then
  git clone -q https://github.com/azooKey/AzooKeyKanaKanjiConverter.git "$DEST"
fi
git -C "$DEST" -c advice.detachedHead=false checkout -q "$REV"
git -C "$DEST" submodule update --init --depth 1
# 当て済みかは、逆に当てられるかで見分ける。当て済みでなく当てられもしないとき（変換エンジンの版の違いなど）は止める
if git -C "$DEST" apply --reverse --check "$MED/eval/anco.patch" 2>/dev/null; then
  echo "anco.patch は当て済み"
else
  git -C "$DEST" apply "$MED/eval/anco.patch"
fi
(cd "$DEST" && swift build -c release --product CliTool --traits Zenzai)
echo "完了: $DEST/.build/release/CliTool"
