#!/bin/bash
# 医療用語の辞書を、元データの取得からアプリに同梱する形まで一度に作る。
# 使い方: bash medical/dictionaries/build_all.sh             （配布する版〔既定〕。万病辞書か百薬辞書を出典に含む語だけ）
#         PERSONAL=1 bash medical/dictionaries/build_all.sh  （手元で使う版。JMED-DICT mini の全部の出典を使う。配布しない）
# 前提: medical/eval/setup_anco.sh で CliTool を作り、medical/harness で dict-builder をビルドしておく
#        （cd medical/harness && swift build -c release --product dict-builder）。
#        7/8（変換を乱す語を除く）に Sudachi を使う: pip install sudachipy sudachidict_core を入れた Python を SUDACHI_PY で渡す
# かかる時間: 今の変換で正しく出るかを45万語について確かめるので、8並列で30分ほど。
#   確かめた結果は問題の sha256 と組で残し、次に作るときは問題が同じ分だけ使い回す（変わった分は確かめ直す）
# ほかに指定できるもの: BUILD_DIR=<作業フォルダ>、JMED_DIR=<JMED-DICT の CSV のフォルダ>、JOBS=<並列数>、ANCO=<CliTool>、
#   SUDACHI_PY=<Sudachi の入った Python>（既定 python3）、AZK_DICT=<変換エンジンの辞書のフォルダ。louds/ のある Dictionary>、
#   CLEAN=0（7/8 を飛ばし、前の作り方で作る。比べるとき用）、CHID・BUILDER・OUT_DIR（make_app_dictionary.sh に渡す）
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
MED="$(cd "$DIR/.." && pwd)"
BUILD="${BUILD_DIR:-$DIR/build}"
export JMED_DIR="${JMED_DIR:-$DIR/sources/jmed}"
ANCO="${ANCO:-$MED/build/AzooKeyKanaKanjiConverter/.build/release/CliTool}"
AZK_DICT="${AZK_DICT:-$MED/build/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/Dictionary}"
SUDACHI_PY="${SUDACHI_PY:-python3}"
CLEAN="${CLEAN:-1}"
JOBS="${JOBS:-8}"
# 公開用か手元用か。指定のないときは公開用。PUBLIC=0 だけでは手元用にしない（取り違えを防ぐ）
PERSONAL="${PERSONAL:-0}"
PUBLIC="${PUBLIC:-}"
if [ "$PERSONAL" = 1 ] && { [ -z "$PUBLIC" ] || [ "$PUBLIC" = 0 ]; }; then
  PUBLIC=0
elif [ "$PERSONAL" = 0 ] && { [ -z "$PUBLIC" ] || [ "$PUBLIC" = 1 ]; }; then
  PUBLIC=1
else
  echo "公開用は何も付けないか PUBLIC=1、手元用は PERSONAL=1 を付けて実行する（今の指定: PERSONAL=${PERSONAL} PUBLIC=${PUBLIC}）"
  exit 1
fi
[ -x "$ANCO" ] || { echo "CliTool がない: ${ANCO}（medical/eval/setup_anco.sh を先に実行）"; exit 1; }
case "$JOBS" in ''|*[!0-9]*|0) echo "JOBS は1以上の数: ${JOBS}"; exit 1 ;; esac
case "$CLEAN" in
  1)
    "$SUDACHI_PY" -I -c 'import sudachipy, sudachidict_core' 2>/dev/null || {
      echo "Sudachi の入った Python がない: ${SUDACHI_PY}（pip install sudachipy sudachidict_core を入れて SUDACHI_PY=<python> で渡す。7/8 を飛ばすなら CLEAN=0）"; exit 1; }
    [ -d "$AZK_DICT/louds" ] || { echo "変換エンジンの辞書がない: ${AZK_DICT}/louds（AZK_DICT で渡す）"; exit 1; } ;;
  0) ;;
  *) echo "CLEAN は 1 か 0: ${CLEAN}"; exit 1 ;;
esac
echo "作る版: $([ "$PUBLIC" = 1 ] && echo '公開用（万病辞書か百薬辞書を出典に含む語だけ）' || echo '手元用（全部の出典。配布しない）')"
mkdir -p "$BUILD"
FILTER="$BUILD/filter"
STAMP=$(date +%Y%m%d-%H%M%S)
# 途中で止まったときに、書きかけの確認結果（.part）を残さない
trap 'rm -f "$FILTER"/result*.json.part' EXIT

echo "[1/8] JMED-DICT mini を取得して照合"
bash "$DIR/download_jmed.sh"

echo "[2/8] 読みと表記を取り出す"
python3 -I "$DIR/build_medical_tsv.py" "$JMED_DIR" "$BUILD/jmed_all.tsv"

echo "[3/8] 今の変換で正しく出るかを確かめる（$JOBS 並列）"
python3 -I "$DIR/select_entries.py" prepare "$BUILD/jmed_all.tsv" "$FILTER" "$JOBS"
# 1つ分の問題を確かめる。結果には問題の sha256 を添え、同じ問題の結果があれば使い回す
run_chunk() {
  local i="$1" sha="$2"
  local chunk="$FILTER/chunk$i.json" result="$FILTER/result$i.json"
  [ "$(shasum -a 256 "$chunk" | cut -d' ' -f1)" = "$sha" ] || { echo "    chunk$i.json が prepare のときと違う"; return 1; }
  if [ -f "$result" ] && [ "$(cat "$result.chunk-sha256" 2>/dev/null)" = "$sha" ]; then
    echo "    chunk$i: 問題が前と同じなので、前の結果を使う"
    return 0
  fi
  # 前の問題に対する結果は消さずに退避する
  if [ -e "$result" ] || [ -e "$result.chunk-sha256" ]; then
    mkdir -p "$FILTER/old/$STAMP"
    for f in "$result" "$result.chunk-sha256"; do
      if [ -e "$f" ]; then
        mv "$f" "$FILTER/old/$STAMP/"
      fi
    done
  fi
  "$ANCO" evaluate "$chunk" --output "$result.part" >"$result.log" 2>&1
  mv "$result.part" "$result"
  echo "$sha" > "$result.chunk-sha256"
  echo "    chunk$i: 確かめた"
}
PIDS=()
NAMES=()
while read -r sha name; do
  case "$name" in chunk*.json) ;; *) continue ;; esac
  i="${name#chunk}"
  i="${i%.json}"
  run_chunk "$i" "$sha" </dev/null &
  PIDS+=("$!")
  NAMES+=("$i")
done < "$FILTER/chunks.sha256"
FAILED=0
for k in "${!PIDS[@]}"; do
  if ! wait "${PIDS[$k]}"; then
    echo "確かめるのに失敗した: chunk${NAMES[$k]}.json（ログ: $FILTER/result${NAMES[$k]}.json.log）"
    FAILED=1
  fi
done
[ "$FAILED" = 0 ] || exit 1

echo "[4/8] 今の変換で1位に出ない語を残す"
python3 -I "$DIR/select_entries.py" collect "$FILTER" "$BUILD/needed.tsv" "$BUILD/markers_jmed.txt"

echo "[5/8] 誤字と揺れを除く"
if [ "$PUBLIC" = 1 ]; then
  # 公開用: 誤字の判定の前に、公開できる出典の表記だけで読みごとの1位を選び直す
  python3 -I "$DIR/refine_entries.py" "$JMED_DIR" "$FILTER/candidates.tsv" "$BUILD/needed.tsv" "$BUILD/needed_refined.tsv" --public
else
  python3 -I "$DIR/refine_entries.py" "$JMED_DIR" "$FILTER/candidates.tsv" "$BUILD/needed.tsv" "$BUILD/needed_refined.tsv"
fi

echo "[6/8] もとの辞書で候補に出せる語と、語の断片を除く"
python3 -I "$DIR/keep_missing.py" "$JMED_DIR" "$FILTER" "$BUILD/needed_refined.tsv" "$BUILD/needed_missing.tsv"

echo "[7/8] 読みの合わない語・語の断片・助詞などの付いた語・普段の語とぶつかる短い語を除く"
if [ "$CLEAN" = 1 ]; then
  # 外した語は dropped_entries.tsv（理由つき）、強く効かせる版だけから外す語は strong_exclude.tsv に書く
  "$SUDACHI_PY" -I "$DIR/clean_entries.py" "$JMED_DIR" "$FILTER" "$BUILD/needed_missing.tsv" "$BUILD/needed_clean.tsv" \
    "$BUILD/strong_exclude.tsv" "$BUILD/dropped_entries.tsv" --anco "$ANCO" --azk-dict "$AZK_DICT"
  NEEDED_FINAL="$BUILD/needed_clean.tsv"
  STRONG_EXCLUDE_FILE="$BUILD/strong_exclude.tsv"
else
  echo "    CLEAN=0 なので飛ばす"
  NEEDED_FINAL="$BUILD/needed_missing.tsv"
  STRONG_EXCLUDE_FILE=""
fi

echo "[8/8] アプリに同梱する形に変換"
# 公開用では、make_app_dictionary.sh が出典の絞り込み（license_filter.py）をもう一度かける
NEEDED="$NEEDED_FINAL" STRONG_EXCLUDE="$STRONG_EXCLUDE_FILE" CLEANED="$CLEAN" BUILD_DIR="$BUILD" PUBLIC="$PUBLIC" PERSONAL="$PERSONAL" \
  bash "$DIR/make_app_dictionary.sh"
echo "完了: ${OUT_DIR:-$BUILD/app_dictionary}（medical/scripts/build_install.sh が同梱する）"
