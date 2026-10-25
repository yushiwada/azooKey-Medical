"""同じ読みの語の中から、誤字や揺れを除いて表記を選ぶ。
JMED-DICT の「出現形」は実際の文書に出た表記なので、「前立線肥大症」「症侯群」のような誤字も入っている。
読みごとに、頻度がいちばん高い表記と、それに近い頻度（2割以上かつ5回以上）の表記だけを残す。
頻度がすべて0の読みは、正規形が自分自身の表記、出典の数が多い表記を優先して1つだけ残す。
--public を付けると（公開用）、出典に万病辞書か百薬辞書を含む表記だけで読みごとの1位を選び直す。
  公開できない表記が1位のために、公開できる正しい表記まで外れるのを防ぐ（例: 「アンピシリンスルバクタム」は、
  公開できない「アンピシリン‐スルバクタム」が1位のために外れていた）。
  ただし、公開できない1位の表記は文書に出ている（頻度1以上）のに、代わりの表記の頻度が0のときは代えない
  （「網膜病変」の代わりに誤字の「毛膜病変」、「SLE増悪」の代わりに「SLE憎悪」が入るのを防ぐ）。
使い方: python3 -I refine_entries.py <sources/jmed> <candidates.tsv> <needed.tsv> <出力.tsv> [--public]
"""
import csv
import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

FILES = ["DISEASE_mini.csv", "MEDICATION_mini.csv", "BODY_mini.csv", "TEST_mini.csv"]
SMALL_KANA_START = tuple("ャュョッァィゥェォヮヵヶゃゅょっぁぃぅぇぉゎー")
OPEN_SOURCES = {"MANBYO", "HAKUYAKU"}
# 読みの正規化は build_medical_tsv.py と同じ
HIRAGANA_READING = re.compile(r"^[ぁ-ゖゔー]+$")


def to_hiragana(text):
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in text)


def normalize_reading(raw):
    reading = unicodedata.normalize("NFKC", raw).replace(" ", "").replace("　", "")
    reading = to_hiragana(reading)
    return reading if HIRAGANA_READING.match(reading) else None


def evidence_reading(raw):
    """出典の照合に使う読み（license_filter.py と同じ）。末尾の「？」（読みが確かでないという印）は外して照合する"""
    reading = normalize_reading(raw)
    if reading is None:
        text = unicodedata.normalize("NFKC", raw).strip()
        if text.endswith("?"):
            reading = normalize_reading(text[:-1])
    return reading


def load_extra(src):
    """表記 → (正規形が自分自身か, 出典の数) と、出典に万病辞書か百薬辞書を含む (読み, 表記) の組"""
    extra = {}
    open_pairs = set()
    for name in FILES:
        with open(src / name, encoding="utf-8-sig", newline="") as f:
            for row in csv.DictReader(f):
                surface = unicodedata.normalize("NFKC", (row.get("出現形") or "").strip())
                canonical = unicodedata.normalize("NFKC", (row.get("正規形") or "").strip())
                sources = {s.strip() for s in (row.get("SOURCE") or "").split(";") if s.strip()}
                old = extra.get(surface, (False, 0))
                extra[surface] = (old[0] or canonical == surface, max(old[1], len(sources)))
                if sources & OPEN_SOURCES:
                    for raw in (row.get("出現形よみ") or "").split(";"):
                        if not raw.strip() or raw.strip() == "-1":
                            continue
                        reading = evidence_reading(raw)
                        if reading:
                            open_pairs.add((reading, surface))
    return extra, open_pairs


def main():
    args = [a for a in sys.argv[1:] if a != "--public"]
    public = "--public" in sys.argv
    if len(args) != 4:
        sys.exit(__doc__)
    src, candidates_path, needed_path, out_path = Path(args[0]), args[1], args[2], Path(args[3])
    extra, open_pairs = load_extra(src)
    groups = defaultdict(list)
    for line in open(candidates_path, encoding="utf-8"):
        reading, surface, category, freq, flag = line.rstrip("\n").split("\t")
        groups[reading].append((surface, int(freq)))
    keep = set()
    substituted = not_substituted = 0
    for reading, items in groups.items():
        items = [(s, f) for s, f in items if not s.startswith(SMALL_KANA_START)]
        if not items:
            continue
        ranked = sorted(items, key=lambda x: (x[1], extra.get(x[0], (False, 0))[0], extra.get(x[0], (False, 0))[1]), reverse=True)
        if public:
            top_all = ranked[0]
            ranked = [x for x in ranked if (reading, x[0]) in open_pairs]
            if not ranked:
                continue
            if ranked[0] != top_all:
                if ranked[0][1] == 0 and top_all[1] > 0:
                    not_substituted += 1
                    continue
                substituted += 1
        top_surface, top_freq = ranked[0]
        keep.add((reading, top_surface))
        if top_freq > 0:
            for s, f in ranked[1:]:
                if f >= max(5, 0.2 * top_freq):
                    keep.add((reading, s))
    kept = dropped = 0
    tmp = out_path.with_name(out_path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as out:
        for line in open(needed_path, encoding="utf-8"):
            if line.startswith("#"):
                out.write(line)
                continue
            cols = line.rstrip("\n").split("\t")
            if (cols[0], cols[1]) in keep:
                out.write(line)
                kept += 1
            else:
                dropped += 1
    tmp.replace(out_path)
    note = f"。公開用: 公開できない1位の代わりに選んだ読み {substituted}、代わりが頻度0なので選ばなかった読み {not_substituted}" if public else ""
    print(f"残す {kept} 語 / 除く {dropped} 語（誤字や揺れ{'・公開できない出典だけの語' if public else ''}）{note}")


if __name__ == "__main__":
    main()
