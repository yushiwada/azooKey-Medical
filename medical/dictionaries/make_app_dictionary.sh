#!/bin/bash
# 選別済みの語（needed_missing.tsv）から、アプリに同梱する医療用語の辞書を作る。
#   strong/ … 前の文章が医療の内容のときに使う（強く効かせる）
#   weak/   … それ以外で使う（候補には出るが、普段の語より前には出にくい）
#   markers.txt … 医療の文脈かを判定する語
#   NOTICE.txt … 出典の表示（公開用と手元用で文面が違う）
#   BUILD_INFO … 公開用か（PUBLIC=1/0）、元にしたファイルの sha256、作った日時。配布の zip を作るときに確かめる
# 既定は公開用: 出典に万病辞書か百薬辞書を含む語だけにする（ここで license_filter.py をかける）。personal/ は使わない
# PERSONAL=1 を付けると手元用: JMED-DICT mini の全部の出典と、個人用の追加語（personal/*.tsv、読み<TAB>表記）を使う。配布しない
# ほかに指定できるもの: NEEDED=<語のTSV>、BUILD_DIR=<作業フォルダ>、OUT_DIR=<出力フォルダ>、JMED_DIR=<JMED-DICT の CSV のフォルダ>、
#   CHID=<文字表>、BUILDER=<dict-builder>、STRONG_COST・WEAK_COST・MIN_FREQ
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
MED="$(cd "$DIR/.." && pwd)"
BUILD="${BUILD_DIR:-$DIR/build}"
JMED="${JMED_DIR:-$DIR/sources/jmed}"
# 変換エンジンの文字表（medical/eval/setup_anco.sh が取ってくる変換エンジンの中にある）
CHID="${CHID:-$MED/build/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/Dictionary/louds/charID.chid}"
BUILDER="${BUILDER:-$MED/harness/.build/release/dict-builder}"
[ -f "$CHID" ] || { echo "文字表がない: ${CHID}（medical/eval/setup_anco.sh を先に実行）"; exit 1; }
[ -x "$BUILDER" ] || { echo "dict-builder がない: ${BUILDER}（cd medical/harness && swift build -c release --product dict-builder）"; exit 1; }
STRONG=${STRONG_COST:--8}
WEAK=${WEAK_COST:--16}
MIN_FREQ=${MIN_FREQ:-0}
NEEDED="${NEEDED:-$BUILD/needed_missing.tsv}"
[ -f "$NEEDED" ] || { echo "語の TSV がない: ${NEEDED}（build_all.sh で作る）"; exit 1; }
[ -f "$BUILD/markers_jmed.txt" ] || { echo "判定用の語の一覧がない: $BUILD/markers_jmed.txt（build_all.sh で作る）"; exit 1; }

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

FINAL="${OUT_DIR:-$BUILD/app_dictionary}"
# 毎回新しいフォルダに作り、最後に入れ替える（古い版は消さずに build/old/ へ退避）
OUT="$FINAL.new.$$"
STOP=$(mktemp "${TMPDIR:-/tmp}/azkm-stoplist.XXXXXX")
cleanup() {
  rm -f "$STOP"
  # 途中で止まったときは、作りかけのフォルダを消さずに old/ へ移す
  if [ -d "$OUT" ]; then
    mkdir -p "$BUILD/old"
    mv "$OUT" "$BUILD/old/$(basename "$FINAL")-failed-$(date +%Y%m%d-%H%M%S)"
  fi
}
trap cleanup EXIT

if [ "$PUBLIC" = 1 ]; then
  # 公開用: 渡された TSV が何であっても、ここで万病辞書か百薬辞書を出典に含む語だけにする
  python3 -I "$DIR/license_filter.py" "$JMED" "$NEEDED" "$BUILD/needed_public.tsv"
  ENTRIES="$BUILD/needed_public.tsv"
  PERSONAL_FILES=()
else
  ENTRIES="$NEEDED"
  PERSONAL_FILES=()
  for p in "$DIR"/personal/*.tsv; do
    if [ -f "$p" ]; then
      PERSONAL_FILES+=("$p")
    fi
  done
fi

mkdir -p "$OUT"
for kind in strong weak; do
  cost=$([ "$kind" = strong ] && echo "$STRONG" || echo "$WEAK")
  tsv="$BUILD/$kind.tsv"
  # 個人用の語（手元用だけ）と選別済みの語を、読み<TAB>表記<TAB>コスト にまとめる。
  # 改行の CR や先頭の BOM は外し、読みがかな以外・制御文字を含む行があれば止める
  python3 -I - "$cost" "$MIN_FREQ" "$tsv" "$ENTRIES" ${PERSONAL_FILES[@]+"${PERSONAL_FILES[@]}"} <<'PY'
import re
import sys
import unicodedata

cost, min_freq, out, entries, *personal = sys.argv[1:]
KANA = re.compile(r"^[ぁ-ゖァ-ヺー]+$")
lines = []
bad = []


def has_control(text):
    # 制御文字・書式文字（ゼロ幅の文字や BOM など）・行と段落の区切り
    return any(unicodedata.category(ch) in ("Cc", "Cf", "Zl", "Zp") for ch in text)


def check(path, n, reading, surface):
    if not KANA.match(reading) or not surface or has_control(reading + surface):
        bad.append(f"{path}:{n}: {reading!r}\t{surface!r}")
        return False
    return True


for path in personal:
    with open(path, encoding="utf-8-sig") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\r\n")
            if not line.strip() or line.startswith("#"):
                continue
            cols = [c.strip() for c in line.split("\t")]
            if len(cols) < 2:
                bad.append(f"{path}:{n}: 読み<TAB>表記 になっていない: {line!r}")
                continue
            if check(path, n, cols[0], cols[1]):
                lines.append(f"{cols[0]}\t{cols[1]}\t{cost}\n")
with open(entries, encoding="utf-8") as f:
    for n, line in enumerate(f, 1):
        if line.startswith("#"):
            continue
        cols = line.rstrip("\n").split("\t")
        if len(cols) < 4 or not cols[3].lstrip("-").isdigit():
            bad.append(f"{entries}:{n}: 列が足りない: {line!r}")
            continue
        if int(cols[3]) >= int(min_freq) and check(entries, n, cols[0], cols[1]):
            lines.append(f"{cols[0]}\t{cols[1]}\t{cost}\n")
if bad:
    sys.exit("辞書に入れられない行がある:\n" + "\n".join(bad[:20]) + (f"\n…ほか {len(bad) - 20} 行" if len(bad) > 20 else ""))
with open(out, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY
  "$BUILDER" "$CHID" "$OUT/$kind" "$tsv" | tee "$BUILD/$kind.builder.log"
done
# dict-builder が書き出した語の数（同じ読みと表記の重複と、文字表にない文字を含む読みを除いたあと）
WRITTEN=$(sed -n 's/^書き出し: \([0-9]*\) 語（除外 \([0-9]*\) 行）.*/\1 \2/p' "$BUILD/weak.builder.log")
[ -n "$WRITTEN" ] || { echo "dict-builder の出力から語の数を読めない（$BUILD/weak.builder.log）"; exit 1; }

# 出典の表示（CC BY 4.0 の条件）。アプリに同梱するので辞書と一緒に置く
if [ "$PUBLIC" = 1 ]; then
  cat > "$OUT/NOTICE.txt" <<'NOTICE'
この医療用語の辞書は、JMED-DICT mini（奈良先端科学技術大学院大学 JMED-DICT 作業班、CC BY 4.0）をもとに作成しました。
https://huggingface.co/datasets/sociocom/JMED-DICT_mini （版 a0f5c997113947bb1be6264eddfdbe5ed1da25a3）
ライセンス: https://creativecommons.org/licenses/by/4.0/deed.ja
この版は公開用で、出典に万病辞書（MANBYO_202106、https://sociocom.naist.jp/manbyou-dic/ ）か百薬辞書（HYAKUYAKU_202107、https://sociocom.naist.jp/hyakuyaku-dic/ 。データの SOURCE 列では HAKUYAKU と表記）を含む語だけを使っています。どちらも奈良先端科学技術大学院大学が CC BY 4.0 で公開している資料です。
変更点: 読みと表記だけを取り出し、誤字・語の断片・もとの辞書で候補に出せる語を除き、変換エンジンの辞書形式に変換しました。
NOTICE
else
  cat > "$OUT/NOTICE.txt" <<'NOTICE'
個人用。JAMSMDIC など再配布できない出典を含むため配布しない。
この医療用語の辞書は、JMED-DICT mini（奈良先端科学技術大学院大学 JMED-DICT 作業班、CC BY 4.0）の全部の出典と、手元の追加語（personal/）から作った手元用の版です。
日本医学会 医学用語辞典（JAMSMDIC）のように再利用を禁じている資料や、再配布の条件を確かめていない資料に由来する語を含みます。配布する zip やアプリに入れないでください。
https://huggingface.co/datasets/sociocom/JMED-DICT_mini （版 a0f5c997113947bb1be6264eddfdbe5ed1da25a3）
NOTICE
fi

grep -v '^#' "$DIR/markers_stoplist.txt" > "$STOP" || true
MARKERS_JMED="$BUILD/markers_jmed.txt"
if [ "$PUBLIC" = 1 ]; then
  # 公開用: 判定用の語も、万病辞書か百薬辞書を出典に含む語だけにする
  python3 -I "$DIR/license_filter.py" "$JMED" "$BUILD/markers_jmed.txt" "$BUILD/markers_jmed_public.txt" --words
  MARKERS_JMED="$BUILD/markers_jmed_public.txt"
fi
{ grep -v '^#' "$DIR/markers_clinical.txt"; cat "$MARKERS_JMED"; } | awk 'length($0)>=2' | grep -vxFf "$STOP" | sort -u > "$OUT/markers.txt"

# 作り方の記録。ファイルは名前だけを書き、置き場所（ホームフォルダのパス）は書かない
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
{
  echo "# azooKey Medical の医療用語の辞書の作り方の記録（make_app_dictionary.sh が書く）"
  echo "PUBLIC=$PUBLIC"
  echo "CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  commit=$(git -C "$MED" rev-parse HEAD 2>/dev/null || echo unknown)
  if [ "$commit" != unknown ] && [ -n "$(git -C "$MED" status --porcelain -- dictionaries 2>/dev/null)" ]; then
    commit="$commit-dirty"
  fi
  echo "SCRIPTS_COMMIT=$commit"
  echo "JMED_DICT_MINI_REVISION=a0f5c997113947bb1be6264eddfdbe5ed1da25a3"
  echo "STRONG_COST=$STRONG"
  echo "WEAK_COST=$WEAK"
  echo "MIN_FREQ=$MIN_FREQ"
  echo "ENTRIES=${WRITTEN% *}"
  echo "SKIPPED_LINES=${WRITTEN#* }"
  echo "PERSONAL_FILES=${#PERSONAL_FILES[@]}"
  echo "MARKERS=$(wc -l < "$OUT/markers.txt" | tr -d ' ')"
  for f in "$JMED"/DISEASE_mini.csv "$JMED"/MEDICATION_mini.csv "$JMED"/BODY_mini.csv "$JMED"/TEST_mini.csv; do
    echo "SHA256 $(sha "$f") jmed/$(basename "$f")"
  done
  echo "SHA256 $(sha "$NEEDED") $(basename "$NEEDED")"
  if [ "$PUBLIC" = 1 ]; then
    echo "SHA256 $(sha "$ENTRIES") $(basename "$ENTRIES")"
  fi
  for p in ${PERSONAL_FILES[@]+"${PERSONAL_FILES[@]}"}; do
    echo "SHA256 $(sha "$p") personal/$(basename "$p")"
  done
  echo "SHA256 $(sha "$BUILD/markers_jmed.txt") markers_jmed.txt"
  echo "SHA256 $(sha "$DIR/markers_clinical.txt") markers_clinical.txt"
  echo "SHA256 $(sha "$DIR/markers_stoplist.txt") markers_stoplist.txt"
  echo "SHA256 $(sha "$CHID") charID.chid"
  echo "SHA256 $(sha "$BUILD/strong.tsv") strong.tsv"
  echo "SHA256 $(sha "$BUILD/weak.tsv") weak.tsv"
} > "$OUT/BUILD_INFO"

if [ -d "$FINAL" ]; then
  mkdir -p "$BUILD/old"
  mv "$FINAL" "$BUILD/old/$(basename "$FINAL")-$(date +%Y%m%d-%H%M%S)"
fi
mv "$OUT" "$FINAL"
echo "$([ "$PUBLIC" = 1 ] && echo 公開用 || echo 手元用): 語 ${WRITTEN% *}・判定用の語 $(wc -l < "$FINAL/markers.txt" | tr -d ' ') → $FINAL"
