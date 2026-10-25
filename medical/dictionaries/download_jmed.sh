#!/bin/bash
# JMED-DICT mini（NAIST、CC BY 4.0）を版を固定して取得し、sha256 を全桁照合する。
# 出典: https://huggingface.co/datasets/sociocom/JMED-DICT_mini
# 取得先のフォルダは JMED_DIR=<フォルダ> で変えられる（既定は medical/dictionaries/sources/jmed）
set -euo pipefail
REV=a0f5c997113947bb1be6264eddfdbe5ed1da25a3
BASE="https://huggingface.co/datasets/sociocom/JMED-DICT_mini/resolve/$REV/data"
OUT="${JMED_DIR:-$(cd "$(dirname "$0")" && pwd)/sources/jmed}"
mkdir -p "$OUT"
PART=""
# 途中で止まったときに、取得しかけのファイル（.part）を残さない
trap '[ -n "$PART" ] && rm -f "$PART"' EXIT
# ファイル名 パス sha256（2026-10-24 に確認）
while read -r name path expected; do
  dest="$OUT/$name"
  if [ ! -f "$dest" ]; then
    echo "取得: $name"
    PART="$dest.part"
    # https 以外への接続と転送を断る
    curl -sSL --fail --proto '=https' --proto-redir '=https' -o "$PART" "$BASE/$path"
    mv "$PART" "$dest"
    PART=""
  fi
  actual=$(shasum -a 256 "$dest" | cut -d' ' -f1)
  if [ "$actual" != "$expected" ]; then
    # 一致しないファイルは使わない。消さずに .bad へ名前を変えて止める
    bad="$dest.bad"
    [ -e "$bad" ] && bad="$dest.bad-$(date +%Y%m%d-%H%M%S)"
    mv "$dest" "$bad"
    echo "sha256 が一致しない: ${name}（${actual} != ${expected}）→ ${bad} に移した"
    exit 1
  fi
  echo "OK: $name"
done <<'LIST'
DISEASE_mini.csv disease/DISEASE_mini.csv 253354f7869d0a5d372b9bba676ced5524c2722f759c1784284451f25ed4592b
MEDICATION_mini.csv medication/MEDICATION_mini.csv 67ffb0bda0ff6f71dad507d517ad1f2b41fc3df13851dcf7149863bf819706ce
BODY_mini.csv body/BODY_mini.csv 2a858f11aefd767ad7731d161964131b67dff2e24d14244d2420fb7b1863329d
TEST_mini.csv test/TEST_mini.csv e5770361f615ad2be19d741ebdb8b384e9e9a3cf850a5097b1cc2dc646310e94
LIST
