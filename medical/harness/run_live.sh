#!/bin/bash
# IME の中核を1打鍵ずつ動かして、ライブ変換・予測・処理時間を確かめる。
# 使い方: bash medical/harness/run_live.sh [ケースのTSV]（既定は cases_final.tsv）
#   TSV の各行: 前の文章<TAB>ローマ字[<TAB>後ろの文章<TAB>文書の先頭]（改行は \n と書く）
set -euo pipefail
HARNESS="$(cd "$(dirname "$0")" && pwd)"
MED="$(cd "$HARNESS/.." && pwd)"
REPO="$(cd "$MED/.." && pwd)"
CASES="${1:-$HARNESS/cases_final.tsv}"
GGUF="$REPO/azooKeyMac/Resources/gguf/ggml-model-Q5_K_M.gguf"
# 変換AIのモデルが本物か（Git LFS で取り込めていないと、変換AIなしで黙って動いてしまう）
if [ "$(head -c 4 "$GGUF" 2>/dev/null || true)" != GGUF ]; then
  echo "変換AIのモデルが本物でない（先頭が GGUF でない）: ${GGUF}（git lfs pull で取り込む）"
  exit 1
fi
(cd "$HARNESS" && swift build -c release --product live-harness)
# 変換AIのモデルと辞書は、アプリと同じく「実行ファイルの場所/Contents/Resources」から読まれる
RES="$HARNESS/.build/release/Contents/Resources"
mkdir -p "$RES"
ln -sfn "$GGUF" "$RES/ggml-model-Q5_K_M.gguf"
if [ -d "$MED/dictionaries/build/app_dictionary" ]; then
  ln -sfn "$MED/dictionaries/build/app_dictionary" "$RES/medical_dictionary"
fi
"$HARNESS/.build/release/live-harness" "$CASES" 2>/dev/null | grep -v 'data is not set'
