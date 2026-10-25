"""公開・配布する辞書から、再配布の条件が確かめられない出典だけの語を外す。
JMED-DICT mini は全体として CC BY 4.0 だが、配布元は「再配布するときは各資料の権利を確かめること」としている。
出典（SOURCE 列）に、NAIST が CC BY 4.0 で公開している万病辞書（MANBYO）か百薬辞書（データでは HAKUYAKU と表記）を含む語だけを残す。
（日本医学会 医学用語辞典〔JAMSMDIC〕は再利用を禁じている。JST などは条件を確かめていない）
出典は読みと表記の組ごとに見る（同じ表記でも、その読みを載せている行の出典だけを使う）。
使い方: python3 -I license_filter.py <sources/jmed> <入力.tsv> <出力.tsv>
      python3 -I license_filter.py <sources/jmed> <語の一覧.txt> <出力.txt> --words   （1行1語の一覧を表記で絞る）
"""
import csv
import re
import sys
import unicodedata
from pathlib import Path

OPEN_SOURCES = {"MANBYO", "HAKUYAKU"}
FILES = ["DISEASE_mini.csv", "MEDICATION_mini.csv", "BODY_mini.csv", "TEST_mini.csv"]
# 読みの正規化は build_medical_tsv.py と同じ
HIRAGANA_READING = re.compile(r"^[ぁ-ゖゔー]+$")


def to_hiragana(text):
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in text)


def normalize_reading(raw):
    reading = unicodedata.normalize("NFKC", raw).replace(" ", "").replace("　", "")
    reading = to_hiragana(reading)
    return reading if HIRAGANA_READING.match(reading) else None


def evidence_reading(raw):
    """出典の照合に使う読み。末尾の「？」（読みが確かでないという印。百薬辞書の「さんしし？」など）は外して照合する"""
    reading = normalize_reading(raw)
    if reading is None:
        text = unicodedata.normalize("NFKC", raw).strip()
        if text.endswith("?"):
            reading = normalize_reading(text[:-1])
    return reading


def load_sources(src):
    """(読み, 表記) → 出典の集合 と、表記 → 出典の集合"""
    by_pair = {}
    by_surface = {}
    for name in FILES:
        with open(src / name, encoding="utf-8-sig", newline="") as f:
            for row in csv.DictReader(f):
                surface = unicodedata.normalize("NFKC", (row.get("出現形") or "").strip())
                sources = {s.strip() for s in (row.get("SOURCE") or "").split(";") if s.strip()}
                by_surface.setdefault(surface, set()).update(sources)
                for raw in (row.get("出現形よみ") or "").split(";"):
                    if not raw.strip() or raw.strip() == "-1":
                        continue
                    reading = evidence_reading(raw)
                    if reading:
                        by_pair.setdefault((reading, surface), set()).update(sources)
    return by_pair, by_surface


def main():
    if len(sys.argv) not in (4, 5) or (len(sys.argv) == 5 and sys.argv[4] != "--words"):
        sys.exit(__doc__)
    src, inp, out = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    by_pair, by_surface = load_sources(src)
    kept = dropped = 0
    tmp = out.with_name(out.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        if "--words" in sys.argv:
            for line in open(inp, encoding="utf-8"):
                word = line.strip()
                if word and by_surface.get(word, set()) & OPEN_SOURCES:
                    f.write(word + "\n")
                    kept += 1
                elif word:
                    dropped += 1
        else:
            for line in open(inp, encoding="utf-8"):
                if line.startswith("#"):
                    f.write(line.replace("# 出典:", "# 公開用（万病辞書か百薬辞書を出典に含む語だけ）。出典:", 1))
                    continue
                cols = line.rstrip("\n").split("\t")
                if len(cols) < 2:
                    sys.exit(f"列が足りない行: {line!r}")
                key = (cols[0], cols[1])
                if key not in by_pair:
                    # 読みの正規化が build_medical_tsv.py とずれている。黙って外すと気づけないので止める
                    sys.exit(f"JMED-DICT にない読みと表記の組: {key}（読みの正規化が build_medical_tsv.py と同じか確かめる）")
                if by_pair[key] & OPEN_SOURCES:
                    f.write(line)
                    kept += 1
                else:
                    dropped += 1
    tmp.replace(out)
    print(f"公開用に残す語: {kept}（外した語: {dropped}）")


if __name__ == "__main__":
    main()
