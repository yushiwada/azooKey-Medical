#!/bin/bash
# IME と同じ条件（zenz-v3、推論は5回まで）で変換の評価をする。
# 使い方: bash medical/eval/run_eval.sh <問題.json> <結果.json> [追加の CliTool 引数...]
#   追加の辞書は --config_user_dictionary_dir <辞書>/weak のように渡す（そのフォルダに user.louds がなければ止める。
#   CliTool は、ないフォルダを渡されても黙って辞書なしで評価するため）
# 先に medical/eval/setup_anco.sh で評価用の CliTool を作っておく
# CliTool の出力（警告やエラー）は <結果.json>.log に残す
set -euo pipefail
MED="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$MED/.." && pwd)"
ANCO="${ANCO:-$MED/build/AzooKeyKanaKanjiConverter/.build/release/CliTool}"
GGUF="${GGUF:-$REPO/azooKeyMac/Resources/gguf/ggml-model-Q5_K_M.gguf}"
[ $# -ge 2 ] || { echo "使い方: bash medical/eval/run_eval.sh <問題.json> <結果.json> [追加の CliTool 引数...]"; exit 2; }
[ -x "$ANCO" ] || { echo "評価用の CliTool がない: ${ANCO}（medical/eval/setup_anco.sh を先に実行）"; exit 1; }
# 変換AIのモデルが本物か（Git LFS で取り込めていないと中身が案内の文字だけになり、CliTool は変換AIなしで評価してしまう）
if [ "$(head -c 4 "$GGUF" 2>/dev/null || true)" != GGUF ]; then
  echo "変換AIのモデルが本物でない（先頭が GGUF でない）: ${GGUF}（git lfs pull で取り込む）"
  exit 1
fi
input="$1"; output="$2"; shift 2
[ -f "$input" ] || { echo "問題のファイルがない: $input"; exit 1; }
check_dictionary_dir() {
  if [ ! -f "$1/user.louds" ]; then
    echo "辞書のフォルダに user.louds がない: ${1}（strong か weak のフォルダを渡す）"
    exit 1
  fi
}
prev=""
for arg in "$@"; do
  if [ "$prev" = --config_user_dictionary_dir ]; then
    check_dictionary_dir "$arg"
  fi
  case "$arg" in
    --config_user_dictionary_dir=*) check_dictionary_dir "${arg#*=}" ;;
  esac
  prev="$arg"
done
[ "$prev" != --config_user_dictionary_dir ] || { echo "--config_user_dictionary_dir のあとにフォルダがない"; exit 1; }
if ! "$ANCO" evaluate "$input" --zenz "$GGUF" --zenz_v3 --config_zenzai_inference_limit 5 --output "$output" "$@" >"$output.log" 2>&1; then
  echo "CliTool が失敗した（ログ: ${output}.log）"
  tail -5 "$output.log"
  exit 1
fi
# 結果の件数が問題の数と同じかを確かめる
python3 -I - "$input" "$output" <<'PY'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))
result = json.load(open(sys.argv[2], encoding="utf-8"))["items"]
if len(items) != len(result):
    sys.exit(f"結果の件数 {len(result)} が問題の数 {len(items)} と違う: {sys.argv[2]}")
PY
