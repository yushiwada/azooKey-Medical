"""医療辞書の切り替え（前の文章に医療の語があれば strong、なければ weak）を評価で再現する。
判定の規則は SegmentsManager.isMedicalContext と同じ（2文字以上の語が左文脈の部分文字列に含まれるか）。
使い方: python3 gated_eval.py <markers.txt> <問題.json> <strong結果.json> <weak結果.json> [--show]
問題と結果は順に対応させ、件数や読み・前の文章・正解が一致しないときは止める。
"""
import json
import sys


def check_pairs(inputs, items, path):
    if len(inputs) != len(items):
        sys.exit(f"{path}: 結果の件数 {len(items)} が問題の数 {len(inputs)} と違う")
    for k, (src, item) in enumerate(zip(inputs, items)):
        want = (src["query"], src.get("left_context") or "", src["answer"][0])
        got = (item.get("query"), item.get("left_context") or "", (item.get("answers") or [None])[0])
        if want != got:
            sys.exit(f"{path}: {k + 1}問目の結果が問題と対応しない（問題 {want} / 結果 {got}）")


def load_markers(path):
    with open(path, encoding="utf-8") as f:
        return {w for w in (line.strip() for line in f) if len(w) >= 2}


def is_medical(context, markers, max_len):
    if not context:
        return False
    for start in range(len(context)):
        for length in range(2, min(max_len, len(context) - start) + 1):
            if context[start:start + length] in markers:
                return True
    return False


def main():
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    markers = load_markers(sys.argv[1])
    max_len = max((len(m) for m in markers), default=0)
    inputs = json.load(open(sys.argv[2], encoding="utf-8"))
    strong = json.load(open(sys.argv[3], encoding="utf-8"))["items"]
    weak = json.load(open(sys.argv[4], encoding="utf-8"))["items"]
    check_pairs(inputs, strong, sys.argv[3])
    check_pairs(inputs, weak, sys.argv[4])
    show = "--show" in sys.argv
    by_tag = {}
    total = 0
    for item, s, w in zip(inputs, strong, weak):
        medical = is_medical(item.get("left_context", ""), markers, max_len)
        chosen = s if medical else w
        ok = chosen["max_rank"] == 0
        total += ok
        for tag in item.get("tag", []):
            a, b = by_tag.get(tag, (0, 0))
            by_tag[tag] = (a + ok, b + 1)
        if show:
            first = chosen["outputs"][0]["text"] if chosen["outputs"] else "-"
            print(f'{"医" if medical else "　"} {"○" if ok else "✗"} {item.get("left_context", "")}［{item["query"]}］→ {first}')
    print(f"切替あり: {total}/{len(inputs)}  " + "  ".join(f"{t}: {a}/{b}" for t, (a, b) in sorted(by_tag.items())))


if __name__ == "__main__":
    main()
