"""JMED-DICT mini の CSV から、IME 辞書の元になる TSV（読み<TAB>表記<TAB>分類<TAB>頻度<TAB>読みの信頼度）を作る。
使い方: python3 -I build_medical_tsv.py <sources/jmed> <出力.tsv>
出典: JMED-DICT mini（NAIST、CC BY 4.0）https://huggingface.co/datasets/sociocom/JMED-DICT_mini
"""
import csv
import re
import sys
import unicodedata
from pathlib import Path

FILES = {
    "病名": "DISEASE_mini.csv",
    "薬": "MEDICATION_mini.csv",
    "部位": "BODY_mini.csv",
    "検査": "TEST_mini.csv",
}
HIRAGANA_READING = re.compile(r"^[ぁ-ゖゔー]+$")
HAS_KANJI_OR_KATAKANA = re.compile(r"[一-鿿㐀-䶿々ァ-ヺー]")
BAD_SURFACE_CHARS = re.compile(r"[\s、。，．,.()（）「」『』\[\]【】/／;；:：・…\"'＋+＝=?？!！<>＜＞]")
MAX_SURFACE_LENGTH = 16


def to_hiragana(text):
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in text)


def normalize_reading(raw):
    reading = unicodedata.normalize("NFKC", raw).replace(" ", "").replace("　", "")
    reading = to_hiragana(reading)
    return reading if HIRAGANA_READING.match(reading) else None


def main():
    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    # 同じ読みと表記の組が複数の行（別の CSV を含む）にあるときは、頻度がいちばん高い行の分類・頻度・読みの信頼度を使う。
    # 最初に出た行を使うと、薬の名前が病名の CSV の頻度0の行で決まり、誤字の表記に負けたり断片として外れたりする
    # （例: 「プレドニゾロン」が頻度1の「プレド二ゾロン」〔漢字の二〕に負ける、「アムロジピン」が断片として外れる）。
    # 頻度が同じときは先に出た行を使い、並び順も最初に出た順を保つ
    best = {}
    stats = {}
    replaced = 0
    for category, name in FILES.items():
        kept = 0
        with open(src / name, encoding="utf-8-sig", newline="") as f:
            for row in csv.DictReader(f):
                surface = unicodedata.normalize("NFKC", (row.get("出現形") or "").strip())
                if not surface or surface == "-1" or len(surface) < 2 or len(surface) > MAX_SURFACE_LENGTH:
                    continue
                if BAD_SURFACE_CHARS.search(surface) or not HAS_KANJI_OR_KATAKANA.search(surface):
                    continue
                try:
                    freq = int(row.get("FREQ:GLOBAL") or 0)
                except ValueError:
                    freq = 0
                flag = (row.get("出現形よみ_flag") or "").strip() or "-"
                for raw in (row.get("出現形よみ") or "").split(";"):
                    if not raw.strip() or raw.strip() == "-1":
                        continue
                    reading = normalize_reading(raw)
                    if not reading:
                        continue
                    key = (reading, surface)
                    old = best.get(key)
                    if old is None:
                        best[key] = (reading, surface, category, freq, flag)
                        kept += 1
                    elif freq > old[3]:
                        best[key] = (reading, surface, category, freq, flag)
                        replaced += 1
        stats[category] = kept
    # 頻度の高い順（同じ頻度なら最初に出た順）
    rows = sorted(best.values(), key=lambda r: -r[3])
    tmp = out.with_name(out.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# 出典: JMED-DICT mini（NAIST、CC BY 4.0）。読み\t表記\t分類\t頻度\t読みの信頼度\n")
        for reading, surface, category, freq, flag in rows:
            f.write(f"{reading}\t{surface}\t{category}\t{freq}\t{flag}\n")
    tmp.replace(out)
    print("書き出し:", len(rows), stats, f"（頻度の高い行で置き換えた組: {replaced}）")


if __name__ == "__main__":
    main()
