"""辞書に入れる語を選ぶ。
1) prepare: 交ぜ書き（同じ読みに漢字だけの表記があるのに、ひらがなを含む表記）を外し、
   今の変換で正しく出るかを確かめるための問題（JSON）を分割して書き出す。
   問題と候補の sha256 を chunks.sha256 に書く（結果がどの問題に対するものかを後で確かめるため）
2) collect: 確認結果を読み、今の変換で1位に出ない語だけを残した TSV と、文脈の判定に使う語の一覧を書き出す
使い方:
  python3 -I select_entries.py prepare <jmed_all.tsv> <作業ディレクトリ> <分割数>
  python3 -I select_entries.py collect <作業ディレクトリ> <needed.tsv> <markers.txt>
確認結果（result<i>.json）は、問題（chunk<i>.json）の sha256 を書いた result<i>.json.chunk-sha256 と組で置く（build_all.sh が書く）。
組が合わない・件数や読みと表記が問題と対応しないときは止める。
"""
import hashlib
import json
import re
import sys
import time
from collections import defaultdict
from pathlib import Path

HIRAGANA = re.compile(r"[ぁ-ゖ]")
KANJI = re.compile(r"[一-鿿㐀-䶿々]")
KATAKANA_ONLY = re.compile(r"^[ァ-ヺー]+$")
MANIFEST = "chunks.sha256"
NUMBERED = re.compile(r"^(chunk|result)(\d+)\.json(\.chunk-sha256|\.log|\.part)?$")


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def write_atomic(path, text):
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    tmp.replace(path)


def load_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                continue
            reading, surface, category, freq, flag = line.rstrip("\n").split("\t")
            rows.append((reading, surface, category, int(freq), flag))
    return rows


def load_ranks(workdir):
    """確認結果を (読み, 表記) → 順位（0 が1位、-1 は候補に出ない）で返す。問題と結果の組が崩れていたら止める"""
    manifest = workdir / MANIFEST
    if not manifest.exists():
        sys.exit(f"{manifest} がない（prepare を先に実行する）")
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


def move_aside_numbered(workdir, parts):
    """前に別の分割数で作った chunk・result（番号が parts 以上）を old/ へ移す（消さない）"""
    old = workdir / "old" / time.strftime("%Y%m%d-%H%M%S")
    moved = 0
    for path in sorted(workdir.iterdir()):
        m = NUMBERED.match(path.name)
        if m and int(m.group(2)) >= parts:
            old.mkdir(parents=True, exist_ok=True)
            path.rename(old / path.name)
            moved += 1
    if moved:
        print(f"前の分割の残り {moved} 個を {old} へ移した")


def prepare(tsv, workdir, parts):
    rows = load_tsv(tsv)
    by_reading = defaultdict(list)
    for r in rows:
        by_reading[r[0]].append(r)
    kept = []
    for reading, group in by_reading.items():
        has_plain = any(not HIRAGANA.search(r[1]) for r in group)
        for r in group:
            if has_plain and HIRAGANA.search(r[1]):
                continue
            kept.append(r)
    if not kept:
        sys.exit("候補が0語")
    parts = max(1, min(parts, len(kept)))
    workdir.mkdir(parents=True, exist_ok=True)
    move_aside_numbered(workdir, parts)
    write_atomic(workdir / "candidates.tsv", "".join("\t".join(map(str, r)) + "\n" for r in kept))
    lines = [f"{sha256_of(workdir / 'candidates.tsv')}  candidates.tsv\n"]
    size = (len(kept) + parts - 1) // parts
    for i in range(parts):
        chunk = kept[i * size:(i + 1) * size]
        items = [{"query": r[0], "answer": [r[1]], "tag": [r[2]], "left_context": ""} for r in chunk]
        path = workdir / f"chunk{i}.json"
        write_atomic(path, json.dumps(items, ensure_ascii=False))
        lines.append(f"{sha256_of(path)}  {path.name}\n")
    write_atomic(workdir / MANIFEST, "".join(lines))
    print(f"候補 {len(kept)} 語（交ぜ書き {len(rows) - len(kept)} 語を除外）を {parts} 分割")


MARKER_CATEGORIES = {"病名", "薬"}


def is_marker(surface, freq, category):
    # 部位と検査には「体重」「血圧」のような普段の語も多いので、判定には病名と薬だけを使う
    if category not in MARKER_CATEGORIES or HIRAGANA.search(surface) or freq < 1:
        return False
    if len(KANJI.findall(surface)) >= 2:
        return True
    return bool(KATAKANA_ONLY.match(surface)) and len(surface) >= 4


def collect(workdir, needed_path, markers_path):
    ranks = load_ranks(workdir)
    candidates = [line.rstrip("\n").split("\t") for line in open(workdir / "candidates.tsv", encoding="utf-8")]
    missing = [c for c in candidates if (c[0], c[1]) not in ranks]
    if missing or len(ranks) != len(candidates):
        sys.exit(f"確認結果のない候補が {len(missing)} 語ある（候補 {len(candidates)} 語・結果 {len(ranks)} 語）")
    needed = [c for c in candidates if ranks[(c[0], c[1])] != 0]
    write_atomic(Path(needed_path),
                 "# 出典: JMED-DICT mini（NAIST、CC BY 4.0）。今の変換で1位に出ない語だけ。読み\t表記\t分類\t頻度\t読みの信頼度\n"
                 + "".join("\t".join(c) + "\n" for c in needed))
    stop = set()
    stop_path = Path(__file__).with_name("markers_stoplist.txt")
    if stop_path.exists():
        stop = {w.strip() for w in open(stop_path, encoding="utf-8") if w.strip() and not w.startswith("#")}
    markers = sorted({c[1] for c in candidates if is_marker(c[1], int(c[3]), c[2]) and c[1] not in stop})
    write_atomic(Path(markers_path), "\n".join(markers) + "\n")
    print(f"確認 {len(ranks)} 語のうち、今の変換で1位に出ない語 {len(needed)} 語。文脈の判定に使う語 {len(markers)} 語")


if __name__ == "__main__":
    if len(sys.argv) != 5 or sys.argv[1] not in ("prepare", "collect"):
        sys.exit(__doc__)
    if sys.argv[1] == "prepare":
        prepare(sys.argv[2], Path(sys.argv[3]), int(sys.argv[4]))
    else:
        collect(Path(sys.argv[2]), sys.argv[3], sys.argv[4])
