#!/bin/bash
# 辞書の版ごとに、全部の問題セットを strong / weak で評価し、成績を表にする。
# 使い方: bash medical/eval/eval_matrix.sh <結果ディレクトリ> <版の名前>=<辞書ディレクトリ> [...]
#   辞書ディレクトリは strong/ と weak/ と markers.txt を含むもの（make_app_dictionary.sh の出力）
#   すでにある結果は使い回す。CliTool の出力は <結果>.json.log に残る
set -euo pipefail
EVAL="$(cd "$(dirname "$0")" && pwd)"
RUN="$EVAL/run_eval.sh"
[ $# -ge 1 ] || { echo "使い方: bash medical/eval/eval_matrix.sh <結果ディレクトリ> <版の名前>=<辞書ディレクトリ> [...]"; exit 2; }
OUT="$1"; shift
SETS=(context_pairs context_pairs_holdout medical_context_general_words context_homophones general_regression medical_terms)
# 先に、全部の辞書がそろっているかを確かめる（ないフォルダを渡すと、黙って辞書なしで評価してしまう）
for spec in "$@"; do
  case "$spec" in *=*) ;; *) echo "<版の名前>=<辞書ディレクトリ> の形で渡す: $spec"; exit 1 ;; esac
  dir="${spec#*=}"
  for kind in strong weak; do
    [ -f "$dir/$kind/user.louds" ] || { echo "辞書がない: $dir/$kind/user.louds"; exit 1; }
  done
  [ -f "$dir/markers.txt" ] || { echo "判定用の語の一覧がない: $dir/markers.txt"; exit 1; }
done
mkdir -p "$OUT"

# 並べて走らせた評価を1つずつ待ち、失敗があれば止める
PIDS=()
NAMES=()
start() {  # <結果.json> <run_eval.sh の引数...>
  local result="$1"
  shift
  if [ -f "$result" ]; then
    return 0
  fi
  bash "$RUN" "$@" </dev/null &
  PIDS+=("$!")
  NAMES+=("$result")
}
wait_all() {
  local k failed=0
  for k in "${!PIDS[@]}"; do
    if ! wait "${PIDS[$k]}"; then
      echo "評価に失敗した: ${NAMES[$k]}（ログ: ${NAMES[$k]}.log）"
      failed=1
    fi
  done
  PIDS=()
  NAMES=()
  [ "$failed" = 0 ] || exit 1
}

# 辞書なし
for s in "${SETS[@]}"; do
  start "$OUT/${s}__none.json" "$EVAL/$s.json" "$OUT/${s}__none.json"
done
wait_all
for spec in "$@"; do
  name="${spec%%=*}"; dir="${spec#*=}"
  for kind in strong weak; do
    for s in "${SETS[@]}"; do
      start "$OUT/${s}__${name}_${kind}.json" "$EVAL/$s.json" "$OUT/${s}__${name}_${kind}.json" --config_user_dictionary_dir "$dir/$kind"
    done
    wait_all
  done
done
python3 -I - "$EVAL" "$OUT" "$@" <<'EOF'
import json
import subprocess
import sys

evaldir, out = sys.argv[1], sys.argv[2]
specs = [s.split("=", 1) for s in sys.argv[3:]]
sets = ["context_pairs", "context_pairs_holdout", "medical_context_general_words", "context_homophones", "general_regression", "medical_terms"]
labels = ["対の文脈38", "新しい対20", "医療文脈の普段語20", "同音異義57", "一般30", "医療用語105"]


def acc(s, path):
    result = json.load(open(path, encoding="utf-8"))["items"]
    return sum(r["max_rank"] == 0 for r in result), len(result)


def gated(s, strong, weak, markers):
    res = subprocess.run([sys.executable, "-I", f"{evaldir}/gated_eval.py", markers, f"{evaldir}/{s}.json", strong, weak],
                         capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"gated_eval.py が失敗した（{s}）: {res.stderr.strip() or res.stdout.strip()}")
    a, b = res.stdout.split("切替あり: ")[1].split()[0].split("/")
    return int(a), int(b)


print("設定".ljust(16) + "".join(l.rjust(14) for l in labels))
row = [acc(s, f"{out}/{s}__none.json") for s in sets]
print("辞書なし".ljust(16) + "".join(f"{a}/{b}".rjust(14) for a, b in row))
for name, d in specs:
    for kind in ["strong", "weak"]:
        row = [acc(s, f"{out}/{s}__{name}_{kind}.json") for s in sets]
        print(f"{name} 常に{kind}".ljust(16) + "".join(f"{a}/{b}".rjust(14) for a, b in row))
    row = [gated(s, f"{out}/{s}__{name}_strong.json", f"{out}/{s}__{name}_weak.json", f"{d}/markers.txt") for s in sets]
    print(f"{name} 切替".ljust(16) + "".join(f"{a}/{b}".rjust(14) for a, b in row))
EOF
