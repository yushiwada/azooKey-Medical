"""辞書に入れる語を最終的に絞る。
- もとの変換で候補の10位以内にも出ない語は入れる
- もとから候補に出せる語は入れない（INCLUDE_LONG を True にすると、読みが5文字以上で頻度1以上の語は入れる）
  （読みの短い語〔きかん→器官、だいたい→大腿 など〕は普段の語と同音になりやすいので、前の文章を見て変換AIに選ばせる）
- 頻度0で、もっとよく使われる語の読みの頭か末尾と一致する語は、語の断片とみなして外す
  （例: 「フローゼ症候群」は「ネフローゼ症候群」の断片、「正貧血」は「鉄欠乏性貧血」の末尾の書き損じ）
  ただし、表記が自分自身の正規形になっている語（「アムロジピン」など）は断片とみなさない
使い方: python3 -I keep_missing.py <sources/jmed> <作業ディレクトリ(filter)> <needed_refined.tsv> <出力.tsv>
確認結果は select_entries.py と同じ方法で読み、問題と結果の組が崩れていたら止める。
"""
import csv
import hashlib
import json
import sys
import unicodedata
from pathlib import Path

MIN_LONG_READING = 5
# 読みの長い語も足すか（評価では悪化が出たので既定は足さない）
INCLUDE_LONG = False
FILES = ["DISEASE_mini.csv", "MEDICATION_mini.csv", "BODY_mini.csv", "TEST_mini.csv"]
MANIFEST = "chunks.sha256"


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def load_ranks(workdir):
    """確認結果を (読み, 表記) → 順位（0 が1位、-1 は候補に出ない）で返す。select_entries.py の同名の関数と同じ"""
    manifest = workdir / MANIFEST
    if not manifest.exists():
        sys.exit(f"{manifest} がない（select_entries.py prepare を先に実行する）")
    ranks = {}
    for line in open(manifest, encoding="utf-8"):
        sha, name = line.split()
        path = workdir / name
        if not path.exists() or sha256_of(path) != sha:
            sys.exit(f"{name} が prepare のときと違う（prepare からやり直す）")
        if not name.startswith("chunk"):
            continue
        result = workdir / name.replace("chunk", "result", 1)
        stamp = result.with_name(result.name + ".chunk-sha256")
        if not result.exists() or not stamp.exists() or stamp.read_text(encoding="utf-8").strip() != sha:
            sys.exit(f"{result.name} が今の {name} に対する結果ではない（確認をやり直す）")
        items = json.load(open(path, encoding="utf-8"))
        results = json.load(open(result, encoding="utf-8"))["items"]
        if len(items) != len(results):
            sys.exit(f"{result.name} の件数 {len(results)} が {name} の {len(items)} と違う")
        for item, res in zip(items, results):
            key = (item["query"], item["answer"][0])
            got = (res.get("query"), (res.get("answers") or [None])[0])
            if got != key:
                sys.exit(f"{result.name} の結果が問題と対応しない: 問題 {key} / 結果 {got}")
            ranks[key] = res["max_rank"]
    return ranks


def load_canonical_surfaces(src):
    """正規形（; で複数あるときはそのどれか）が自分自身になっている表記"""
    canonical = set()
    for name in FILES:
        with open(src / name, encoding="utf-8-sig", newline="") as f:
            for row in csv.DictReader(f):
                surface = unicodedata.normalize("NFKC", (row.get("出現形") or "").strip())
                forms = unicodedata.normalize("NFKC", (row.get("正規形") or "").strip())
                if surface in {x.strip() for x in forms.split(";")}:
                    canonical.add(surface)
    return canonical


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    src, workdir, inp, out = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
    rank = load_ranks(workdir)
    canonical = load_canonical_surfaces(src)

    # よく使われる語（頻度1以上）の読みの、頭と末尾の部分（自分自身より短いもの）
    affixes = set()
    for line in open(workdir / "candidates.tsv", encoding="utf-8"):
        reading, surface, category, freq, flag = line.rstrip("\n").split("\t")
        if int(freq) >= 1:
            for k in range(2, len(reading)):
                affixes.add(reading[:k])
                affixes.add(reading[-k:])

    kept = fragments = protected = 0
    tmp = out.with_name(out.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        for line in open(inp, encoding="utf-8"):
            if line.startswith("#"):
                f.write(line)
                continue
            reading, surface, category, freq, flag = line.rstrip("\n").split("\t")
            freq = int(freq)
            if (reading, surface) not in rank:
                sys.exit(f"確認結果のない語がある: {reading} {surface}（作業ディレクトリが {inp} と合っていない）")
            if freq == 0 and reading in affixes:
                if surface not in canonical:
                    fragments += 1
                    continue
                protected += 1
            r = rank[(reading, surface)]
            if r == -1 or (INCLUDE_LONG and len(reading) >= MIN_LONG_READING and freq >= 1):
                f.write(line)
                kept += 1
    tmp.replace(out)
    print(f"辞書に入れる語: {kept}（語の断片として外した語: {fragments}、正規形なので断片とみなさなかった語: {protected}）")


if __name__ == "__main__":
    main()
